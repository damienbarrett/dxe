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
#      E = THIS BOOT's essentials: the parent directory of the first
#          `nix-ld` on PATH, in PATH order -- i.e.
#          dirname "$(dirname "$(command -v nix-ld)")" -- taken as is (not
#          resolved further). install_essentials put the resolved
#          bootstrap-essentials bin directory on PATH (essentials_profile_path),
#          and PATH survives the apple-image /nix remount by design, so E is
#          the essentials output this boot actually runs, e.g.
#          /nix/store/<hash>-dx-bootstrap-essentials. (Amendment 3,
#          coordinator 2026-10-12: on Mac guests -- apple-image storage
#          mode -- the dx-nix volume's root profile is written only by
#          nix_seed_volume on a fresh volume, so after the remount
#          /nix/var/nix/profiles/per-user/root/profile can be a stale
#          generation without nix-ld. The root profile is therefore NEVER
#          consulted: not essentials_profile_store_path, not
#          DX_ESSENTIALS_ROOT's profile.)
#      R = "${DX_VSCODE_SERVER_ROOT:-}", a prefix for every guest path the
#          step inspects or creates (the loader path, the nix-ld library
#          directory, the /tmp marker). Production never sets it. It is
#          never added to link TARGETS (those point into E).
#      DX_ESSENTIALS_ROOT is used only to name the store in rule 4
#          ("${DX_ESSENTIALS_ROOT:-}/nix/store/"; production: /nix/store/).
#    Preconditions, all checked before ANY change:
#      1. nix-ld is on PATH and E/libexec/nix-ld exists. The nix-ld PACKAGE
#         is the store directory two levels above that file's fully
#         resolved path (readlink -f gives <pkg>/bin/nix-ld, since nixpkgs
#         ships libexec/nix-ld -> ../bin/nix-ld). E itself has no
#         nix-support/ (buildEnv and Nix's profile builder drop it).
#      2. LOADER = the first line of <pkg>/nix-support/ldpath: an absolute
#         path whose directory is exactly /lib or /lib64
#         (/lib/ld-linux-aarch64.so.1, /lib64/ld-linux-x86-64.so.2). It is
#         never derived from uname or hard-coded (the QNAP is x86_64).
#      3. E/share/nix-ld/lib/ provides ld.so, libstdc++.so.6, libgcc_s.so.1
#         and libz.so.1 (each resolving to an existing file).
#      4. R$LOADER is absent, or a symlink (dangling or not) whose target
#         TEXT (readlink, not resolved) begins with
#         "${DX_ESSENTIALS_ROOT:-}/nix/store/" -- in production "/nix/store/":
#         a previous nix-ld or a Nix glibc. A symlink to anywhere else
#         (e.g. a real glibc loader on an FHS base, absolute or relative), a
#         regular file, a directory or anything else there is NEVER replaced.
#      5. R/tmp/vscode-skip-server-requirements-check is absent or a regular
#         file with exactly ONE link (amendment 3: a hard-linked file there
#         is refused, so chown/chmod can never reach another name of it); a
#         symlink there is never followed or replaced.
#      A failed precondition: exactly ONE line on stderr, starting
#      "Warning:" and containing "VS Code" and the reason's key word --
#        no nix-ld on PATH, or none in E        -> "nix-ld"
#        ldpath missing or not /lib|/lib64     -> "ldpath"
#        a library missing                     -> that library's name
#        loader path not ours to replace       -> LOADER (e.g. /lib/ld-linux-aarch64.so.1)
#        unusable marker path                  -> "vscode-skip-server-requirements-check"
#      -- nothing on stdout, NOTHING changed under R, no chown call, status 0.
#    Changes:
#      6. R$LOADER becomes a symlink whose target text is EXACTLY
#         "$E/libexec/nix-ld" (so it resolves to nix-ld and is itself under
#         the store, and the next boot may replace it). An existing store
#         symlink is replaced, including one that points at a directory
#         (ln -sfn; a link must never be created inside that directory).
#      7. R/run/current-system/sw/share/nix-ld/lib is a real directory
#         holding exactly one symlink per library name, each with target
#         text EXACTLY "$E/share/nix-ld/lib/<name>" (stale links replaced).
#         nix-ld's built-in defaults then find ld.so and the libraries: no
#         NIX_LD* variable is needed.
#      GC (live-only, not observable at unit tier): every link targets E,
#         this boot's bootstrap-essentials output. E is in the closure of
#         the GC roots this boot keeps: in apple-image mode the import
#         (nix_store_import_registered -> nix_install_image_essentials_root)
#         publishes the resolved per-user root profile of the /nix that
#         install_essentials just used (nix_image_bootstrap_store_paths),
#         and that generation's closure holds E; in direct-volume mode the
#         root profile itself is the GC root. Root sets are replaced only
#         when the image identity changes, and this step re-links every
#         boot, so a later `nix store gc` cannot dangle the links. The
#         WP1.4 live check (recreate dx-test, then connect) is the proof.
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
#  Optional essentials tools (amendment, coordinator 2026-10-11): an
#  EXISTING guest's root profile must receive nix-ld too, best effort.
#    essentials_optional_tools (bootstrap/common.sh) is the one list, as
#      data: one line per tool, "<name> <path relative to the root
#      essentials profile>", in priority order. Today it holds
#          nix-ld libexec/nix-ld
#      WP6.2b (another branch) will add "rsync bin/rsync" -- a one-line
#      addition; nothing else may need to change for it.
#    essentials_first_missing_optional_tool (bootstrap/common.sh): when the
#      per-user root profile
#      ${DX_ESSENTIALS_ROOT:-}/nix/var/nix/profiles/per-user/root/profile
#      exists (the one essentials_profile_installed tests and
#      upgrade_essential_packages replaces), prints the NAME of the first
#      listed tool whose <profile>/<path> does not exist (a dangling link
#      counts as missing) and returns 0; otherwise -- nothing missing, or
#      no installed profile -- prints nothing and returns 1. It never
#      consults PATH.
#    install_essentials (bootstrap/base-and-storage.sh): the required-tool
#      gate is unchanged (a failed required install/upgrade still fails
#      the phase). Afterwards, ONLY when the required gate found nothing
#      missing (no install or upgrade ran this boot -- at most one upgrade
#      per boot), the profile is installed and an optional tool is missing:
#        - one stdout line containing "Upgrading the essentials profile",
#          "optional" and the quoted name ('nix-ld');
#        - upgrade_essential_packages (the real one: remove, install, and
#          its own rollback on failure);
#        - success: PATH is re-resolved from essentials_profile_path (its
#          output first on PATH) and hash -r, as the required path does;
#          then the tool is checked again (amendment 3): if the upgrade
#          reported success but essentials_first_missing_optional_tool
#          still names it, exactly one stderr line containing "Warning:"
#          and its name, no further upgrade, status 0 -- so the gap is not
#          silently re-attempted every boot;
#        - failure: exactly one stderr line containing "Warning:" and the
#          tool's name (upgrade_essential_packages' own rollback warning
#          may also appear), no "Error:" line, no "essentials installation
#          failed" line; "Bootstrap phase: essentials installation
#          completed in" is still printed and the status is 0.
#      It is errexit-safe (bootstrap runs it under set -euo pipefail).
#    The suite drives install_essentials with a recording `nix` function
#    stub (plus a fail-closed fake nix on PATH) and a `command -v` stub that
#    answers from a file, so no real Nix profile is ever touched.
#
#  Docs: docs/guest.md's "## Browsing /persist from the Mac" section names
#    nix-ld, the "first connection" and the server "download"; and
#    (amendment 3) says an existing guest gets nix-ld on its "next boot"
#    naming "QNAP" as well as the Mac, and no longer claims it comes from an
#    "upgrade of the root essentials profile" (false on Mac guests, whose
#    volume profile bootstrap never rewrites)
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
# shellcheck source=../container/dx-nixos-26.05/bootstrap/base-and-storage.sh
source "$BOOTSTRAP_DIR/base-and-storage.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

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

# The fixture's bootstrap-essentials output: this boot's essentials (E) by
# default, its bin directory being what install_essentials put on PATH.
vs_essentials() { printf '%s\n' "$1/store-root/nix/store/6666ffff-dx-bootstrap-essentials"; }
vs_nixld_pkg() { printf '%s\n' "$1/store-root/nix/store/1111aaaa-nix-ld-2.0.6"; }

# vs_stale_profile CASE -- apple-image mode: the volume's per-user root
# profile is an older generation (seeded once, never rewritten) with no
# nix-ld and no nix-ld library set, while this boot's essentials (on PATH)
# have both.
vs_stale_profile() {
    local old="$1/store-root/nix/store/7000aaaa-profile"
    local profiles="$1/store-root/nix/var/nix/profiles/per-user/root"
    mkdir -p "$old/bin"
    printf 'old useradd\n' > "$old/bin/useradd"
    printf '{"elements":{},"version":3}\n' > "$old/manifest.json"
    rm -f "$profiles/profile" "$profiles/profile-1-link"
    ln -s "$old" "$profiles/profile-1-link"
    ln -s profile-1-link "$profiles/profile"
}

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
#
# PATH is: the stubs, then this boot's essentials bin directories (the file
# CASE/essentials-path, colon-separated, if the case wrote one; otherwise
# the fixture's bootstrap-essentials bin), then the ambient PATH with any
# directory holding a real nix-ld removed, so only the fixture can supply it.
vs_run() {
    local dir="$1" mask="${2:-022}" essentials_path ambient="" entry rest
    essentials_path="$(vs_essentials "$dir")/bin"
    if [ -f "$dir/essentials-path" ]; then essentials_path="$(cat "$dir/essentials-path")"; fi
    rest="$PATH"
    while [ -n "$rest" ]; do
        entry="${rest%%:*}"
        case "$rest" in *:*) rest="${rest#*:}" ;; *) rest="" ;; esac
        if [ -n "$entry" ] && [ ! -e "$entry/nix-ld" ]; then ambient="${ambient:+$ambient:}$entry"; fi
    done
    : > "$dir/stdout"
    : > "$dir/stderr"
    rm -f "$dir/continued"
    (
        set -euo pipefail
        umask "$mask"
        PATH="$dir/bin${essentials_path:+:$essentials_path}:$ambient"
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
    local label="$1" dir="$2" loader="$3" guest="$2/guest-root" essentials lib_dir name listing expected_listing
    essentials="${4:-$(vs_essentials "$dir")}"
    eq "$label: status 0" 0 "$VS_RC"
    eq "$label: the caller continues under errexit" yes "$VS_CONTINUED"
    eq "$label: nothing on stderr" "" "$VS_ERR"
    eq "$label: exactly one line on stdout" 1 "$(line_count "$dir/stdout")"
    has "$label: the line names VS Code server support" "$VS_OUT" "VS Code server support"
    has "$label: the line names the loader path" "$VS_OUT" "$loader"
    lacks "$label: the line is not a warning" "$VS_OUT" "Warning"

    ok "$label: $loader is a symlink" test -L "$guest$loader"
    eq "$label: $loader targets this boot's essentials nix-ld exactly" \
        "$essentials/libexec/nix-ld" "$(readlink "$guest$loader" 2>/dev/null)"
    eq "$label: $loader resolves to nix-ld" "$(resolved "$essentials/libexec/nix-ld")" "$(resolved "$guest$loader")"
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
        eq "$label: $name targets this boot's essentials exactly" \
            "$essentials/share/nix-ld/lib/$name" "$(readlink "$lib_dir/$name" 2>/dev/null)"
        eq "$label: $name resolves to the library set's $name" \
            "$(resolved "$essentials/share/nix-ld/lib/$name")" "$(resolved "$lib_dir/$name")"
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
    "$C/store-root/nix/store/"*) test_pass "aarch64: the loader link's target is under the Nix store (the next boot may replace it)" ;;
    *) test_fail "aarch64: the loader link's target is under the Nix store (got [$(readlink "$C/guest-root/lib/ld-linux-aarch64.so.1" 2>/dev/null)])" ;;
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
# The old loader link points at a DIRECTORY in the store (only ln -sfn
# replaces such a link instead of creating one inside the directory).
STALE_DIR="$C/store-root/nix/store/0001stale-nix-ld-1.0"
mkdir -p "$C/guest-root/lib" "$STALE_DIR" "$C/guest-root/$LIB_SUBDIR"
ln -s "$STALE_DIR" "$C/guest-root/lib/ld-linux-aarch64.so.1"
printf 'old zlib\n' > "$C/guest-root/old-libz"
ln -s "$C/guest-root/old-libz" "$C/guest-root/$LIB_SUBDIR/libz.so.1"
printf 'left by dx\n' > "$C/guest-root/tmp/$MARKER_NAME"
chmod 0600 "$C/guest-root/tmp/$MARKER_NAME"
vs_run "$C"
vs_assert_configured "stale" "$C" /lib/ld-linux-aarch64.so.1
eq "stale: nothing was created inside the directory the old loader link pointed at" "" \
    "$(ls -A "$STALE_DIR" 2>&1)"
eq "stale: the file the old libz link pointed at is untouched" "old zlib" "$(cat "$C/guest-root/old-libz" 2>&1)"

C="$(vs_case dangling)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib"
ln -s "$C/store-root/nix/store/9999gone-nix-ld-1.0/libexec/nix-ld" "$C/guest-root/lib/ld-linux-aarch64.so.1"
vs_run "$C"
vs_assert_configured "dangling" "$C" /lib/ld-linux-aarch64.so.1

# ---------------------------------------------------------------------------
test_section "WP1.4: nix-ld comes from this boot's essentials on PATH, never the root profile"

# Apple-image mode (Mac guests): the volume's root profile is a stale
# generation without nix-ld; this boot's essentials, on PATH, have it.
C="$(vs_case appleimage)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
vs_stale_profile "$C"
vs_run "$C"
vs_assert_configured "apple-image" "$C" /lib/ld-linux-aarch64.so.1

# The root profile has nix-ld but this boot's essentials do not: no fallback.
C="$(vs_case profileonly)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/store-root/nix/store/6600aaaa-dx-bootstrap-essentials/bin"
printf 'useradd\n' > "$C/store-root/nix/store/6600aaaa-dx-bootstrap-essentials/bin/useradd"
chmod 0755 "$C/store-root/nix/store/6600aaaa-dx-bootstrap-essentials/bin/useradd"
printf '%s\n' "$C/store-root/nix/store/6600aaaa-dx-bootstrap-essentials/bin" > "$C/essentials-path"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "nix-ld only in the root profile, not in this boot's essentials" "$C" "nix-ld" "$BEFORE"

# After an upgrade this boot, install_essentials puts the new essentials
# first on PATH ahead of the old ones: the first nix-ld on PATH wins.
C="$(vs_case twoess)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
vs_stale_profile "$C"
NEW_ESSENTIALS="$C/store-root/nix/store/6667abcd-dx-bootstrap-essentials"
cp -R "$(vs_essentials "$C")" "$NEW_ESSENTIALS"
printf '%s\n' "$NEW_ESSENTIALS/bin:$(vs_essentials "$C")/bin" > "$C/essentials-path"
vs_run "$C"
vs_assert_configured "new essentials first on PATH" "$C" /lib/ld-linux-aarch64.so.1 "$NEW_ESSENTIALS"

# ---------------------------------------------------------------------------
test_section "WP1.4: a failed precondition warns, changes nothing, and boot goes on"

C="$(vs_case noprofile)"
vs_stubs "$C" x86_64
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "no essentials on PATH (and no profile)" "$C" "nix-ld" "$BEFORE"

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

# A symlink at the loader path that is not ours (its target is not under the
# Nix store): a real glibc loader on an FHS-style base, absolute or relative,
# or a dangling link to somewhere else. Never replaced.
C="$(vs_case fhsloader)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib" "$C/guest-root/usr/lib/aarch64-linux-gnu"
printf 'distribution glibc loader\n' > "$C/guest-root/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
ln -s "$C/guest-root/usr/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1" "$C/guest-root/lib/ld-linux-aarch64.so.1"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a symlink to a distribution loader at the loader path" "$C" "/lib/ld-linux-aarch64.so.1" "$BEFORE"

C="$(vs_case relloader)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib/aarch64-linux-gnu"
printf 'distribution glibc loader\n' > "$C/guest-root/lib/aarch64-linux-gnu/ld-linux-aarch64.so.1"
ln -s aarch64-linux-gnu/ld-linux-aarch64.so.1 "$C/guest-root/lib/ld-linux-aarch64.so.1"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a relative symlink at the loader path" "$C" "/lib/ld-linux-aarch64.so.1" "$BEFORE"

C="$(vs_case foreigndangling)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/lib"
ln -s /opt/dxe-fixture-absent/ld-linux-aarch64.so.1 "$C/guest-root/lib/ld-linux-aarch64.so.1"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a dangling symlink outside the store at the loader path" "$C" "/lib/ld-linux-aarch64.so.1" "$BEFORE"

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

# A regular file with a second name (a hard link) at the marker path: chown
# and chmod would change the other name too, so it is refused.
C="$(vs_case markerhardlink)"
vs_store "$C" aarch64
vs_stubs "$C" x86_64
mkdir -p "$C/guest-root/var"
printf 'keep me\n' > "$C/guest-root/var/other"
chmod 0600 "$C/guest-root/var/other"
ln "$C/guest-root/var/other" "$C/guest-root/tmp/$MARKER_NAME"
BEFORE="$(vs_snapshot "$C/guest-root")"
vs_run "$C"
vs_assert_refused "a hard-linked file at the marker path" "$C" "$MARKER_NAME" "$BEFORE"
eq "a hard-linked file at the marker path: its other name keeps mode 0600" 600 "$(file_mode "$C/guest-root/var/other")"

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
test_section "WP1.4: the optional essentials tools are one list, read from the profile"

if (
    # shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
    source "$BOOTSTRAP_DIR/common.sh"
    declare -F essentials_optional_tools >/dev/null && declare -F essentials_first_missing_optional_tool >/dev/null
); then
    test_pass "bootstrap/common.sh defines essentials_optional_tools and essentials_first_missing_optional_tool"
else
    test_fail "bootstrap/common.sh defines essentials_optional_tools and essentials_first_missing_optional_tool"
fi

OPTIONAL_LIST="$(essentials_optional_tools 2>/dev/null)"
eq "the optional list holds 'nix-ld libexec/nix-ld' exactly once" 1 "$(grep -Fxc 'nix-ld libexec/nix-ld' <<<"$OPTIONAL_LIST")"
eq "every optional entry is '<name> <path relative to the profile>'" "" \
    "$(awk 'NF != 2 || $2 ~ /^\// { print "bad entry: " $0 }' <<<"$OPTIONAL_LIST")"
eq "optional tool names are unique" "" "$(awk '{ print $1 }' <<<"$OPTIONAL_LIST" | LC_ALL=C sort | uniq -d)"

# oe_profile ROOT KIND -- the per-user root profile under ROOT: none (not
# installed), bare (installed, no libexec/nix-ld), nixld (installed, with a
# store link at libexec/nix-ld), dangling (libexec/nix-ld points nowhere).
oe_profile() {
    local root="$1" kind="$2" gen="$1/nix/store/8888hhhh-profile" profiles="$1/nix/var/nix/profiles/per-user/root"
    local nixld="$1/nix/store/1111aaaa-nix-ld-2.0.6"
    mkdir -p "$root"
    [ "$kind" != none ] || return 0
    mkdir -p "$gen/bin" "$profiles"
    ln -s "$gen" "$profiles/profile-1-link"
    ln -s profile-1-link "$profiles/profile"
    case "$kind" in
        nixld)
            mkdir -p "$nixld/bin" "$gen/libexec"
            printf 'fake nix-ld\n' > "$nixld/bin/nix-ld"
            ln -s "$nixld/bin/nix-ld" "$gen/libexec/nix-ld"
            mkdir -p "$root/nix/store/2222bbbb-rsync-3.4.1/bin" "$gen/bin"
            printf 'fake rsync\n' > "$root/nix/store/2222bbbb-rsync-3.4.1/bin/rsync"
            ln -s "$root/nix/store/2222bbbb-rsync-3.4.1/bin/rsync" "$gen/bin/rsync"
            ;;
        dangling)
            mkdir -p "$gen/libexec"
            ln -s "$root/nix/store/0000gone-nix-ld-1.0/bin/nix-ld" "$gen/libexec/nix-ld"
            ;;
        *) : ;;
    esac
}

# oe_find ROOT -- essentials_first_missing_optional_tool against ROOT.
oe_find() {
    OE_FIND_OUT="$( (
        DX_ESSENTIALS_ROOT="$1"
        export DX_ESSENTIALS_ROOT
        essentials_first_missing_optional_tool
    ) 2>&1)"
    OE_FIND_RC=$?
}

R="$(mktemp -d "$WORK/opt-bare.XXXXXX")"; oe_profile "$R/root" bare
oe_find "$R/root"
eq "installed profile without libexec/nix-ld: reports nix-ld" "nix-ld" "$OE_FIND_OUT"
eq "installed profile without libexec/nix-ld: status 0" 0 "$OE_FIND_RC"

R="$(mktemp -d "$WORK/opt-nixld.XXXXXX")"; oe_profile "$R/root" nixld
oe_find "$R/root"
eq "installed profile with libexec/nix-ld: reports nothing" "" "$OE_FIND_OUT"
eq "installed profile with libexec/nix-ld: status 1" 1 "$OE_FIND_RC"

R="$(mktemp -d "$WORK/opt-dangling.XXXXXX")"; oe_profile "$R/root" dangling
oe_find "$R/root"
eq "a dangling libexec/nix-ld counts as missing" "nix-ld" "$OE_FIND_OUT"
eq "a dangling libexec/nix-ld: status 0" 0 "$OE_FIND_RC"

R="$(mktemp -d "$WORK/opt-none.XXXXXX")"; oe_profile "$R/root" none
oe_find "$R/root"
eq "no installed profile: reports nothing (the normal install covers it)" "" "$OE_FIND_OUT"
eq "no installed profile: status 1" 1 "$OE_FIND_RC"

# PATH is never consulted: nix-ld on PATH (and `command -v` saying so) does
# not hide its absence from the profile.
R="$(mktemp -d "$WORK/opt-path.XXXXXX")"; oe_profile "$R/root" bare
mkdir -p "$R/bin"; printf '#!/bin/sh\nexit 0\n' > "$R/bin/nix-ld"; chmod 0755 "$R/bin/nix-ld"
OE_FIND_OUT="$( (
    PATH="$R/bin:$PATH"
    DX_ESSENTIALS_ROOT="$R/root"
    export DX_ESSENTIALS_ROOT
    command() { if [ "${1:-}" = -v ]; then printf '/fake/bin/%s\n' "${2:-}"; return 0; fi; builtin command "$@"; }
    essentials_first_missing_optional_tool
) 2>&1)"
eq "nix-ld on PATH does not count: the profile is what is checked" "nix-ld" "$OE_FIND_OUT"

# The list is data: a second entry (as WP6.2b will add for rsync) is honoured
# in list order with no other change.
R="$(mktemp -d "$WORK/opt-list.XXXXXX")"; oe_profile "$R/root" nixld
rm -f "$R/root/nix/store/8888hhhh-profile/bin/rsync"  # nixld now holds rsync; this case needs it absent
OE_FIND_OUT="$( (
    DX_ESSENTIALS_ROOT="$R/root"
    export DX_ESSENTIALS_ROOT
    essentials_optional_tools() { printf '%s\n' "nix-ld libexec/nix-ld" "rsync bin/rsync"; }
    essentials_first_missing_optional_tool
) 2>&1)"
eq "a listed rsync missing from a profile that has nix-ld is reported" "rsync" "$OE_FIND_OUT"
R="$(mktemp -d "$WORK/opt-list2.XXXXXX")"; oe_profile "$R/root" bare
OE_FIND_OUT="$( (
    DX_ESSENTIALS_ROOT="$R/root"
    export DX_ESSENTIALS_ROOT
    essentials_optional_tools() { printf '%s\n' "nix-ld libexec/nix-ld" "rsync bin/rsync"; }
    essentials_first_missing_optional_tool
) 2>&1)"
eq "with both missing, the first listed tool is reported" "nix-ld" "$OE_FIND_OUT"

# ---------------------------------------------------------------------------
test_section "WP1.4: install_essentials upgrades an existing profile for nix-ld, best effort"

OE_FAIL_CLOSED="$(fake_tool_dir_create "$WORK")"

# oe_run CASE PRESENT PROFILE [INSTALL_RC] [CREATE_NIXLD] -- install_essentials
# under bootstrap's shell options. PRESENT: the tools `command -v` finds
# (from a file the fake install extends with useradd). PROFILE: as
# oe_profile. The recording `nix` stub logs every call; `profile install`
# returns INSTALL_RC and, on success, marks the upgrade and (unless
# CREATE_NIXLD=no) adds libexec/nix-ld to the generation.
# essentials_profile_path answers /es/old/bin before an install and
# /es/new/bin after one. Call as a plain statement (errexit stays on).
oe_run() {
    local dir="$1" present="$2" kind="$3" install_rc="${4:-0}" create="${5:-yes}" tool
    local root="$1/es-root" gen="$1/es-root/nix/store/8888hhhh-profile"
    oe_profile "$root" "$kind"
    : > "$dir/present"
    for tool in $present; do printf '%s\n' "$tool" >> "$dir/present"; done
    : > "$dir/nix.log"
    : > "$dir/handback.log"
    rm -f "$dir/upgraded" "$dir/continued"
    (
        set -euo pipefail
        PATH="$OE_FAIL_CLOSED:$PATH"
        DX_ESSENTIALS_ROOT="$root"
        export DX_ESSENTIALS_ROOT
        unset DX_USAGE_SERVICE
        command() {
            if [ "${1:-}" = -v ]; then
                if grep -Fqx -- "${2:-}" "$dir/present"; then printf '/fake/bin/%s\n' "$2"; return 0; fi
                return 1
            fi
            builtin command "$@"
        }
        essentials_profile_path() {
            if [ -e "$dir/upgraded" ]; then printf '%s\n' /es/new/bin; else printf '%s\n' /es/old/bin; fi
        }
        # int-4 (main's fix/gc-rootpaths): run_root_nix hands root-owned store
        # paths back after every root nix call, with the guest's GNU stat,
        # find and chown (which this case's `command -v` stub hides);
        # tests/test_bootstrap_nix_rootpaths*.sh hold that behaviour. Record
        # each hand-back here instead of running it on this fixture.
        hand_back_root_nix_paths() { printf 'hand-back\n' >> "$dir/handback.log"; }
        nix() {
            printf 'nix %s\n' "$*" >> "$dir/nix.log"
            case "$*" in
                *"profile install"*)
                    if [ "$install_rc" -eq 0 ]; then
                        : > "$dir/upgraded"
                        printf 'useradd\n' >> "$dir/present"
                        if [ "$create" = yes ] && [ -d "$gen" ]; then
                            mkdir -p "$gen/libexec"
                            printf 'fake nix-ld\n' > "$gen/libexec/nix-ld"
                            printf 'fake rsync\n' > "$gen/bin/rsync"
                        fi
                    fi
                    return "$install_rc"
                    ;;
            esac
            return 0
        }
        install_essentials
        printf '%s\n' "$PATH" > "$dir/path"
        : > "$dir/continued"
    ) > "$dir/stdout" 2> "$dir/stderr"
    OE_RC=$?
    OE_OUT="$(cat "$dir/stdout")"
    OE_ERR="$(cat "$dir/stderr")"
    OE_NIX="$(cat "$dir/nix.log")"
    OE_PATH="$(cat "$dir/path" 2>/dev/null)"
    OE_CONTINUED=no
    if [ -f "$dir/continued" ]; then OE_CONTINUED=yes; fi
}
PROFILE_REMOVE="nix profile remove --profile /nix/var/nix/profiles/per-user/root/profile bootstrap-essentials"
PROFILE_INSTALL="nix profile install --profile /nix/var/nix/profiles/per-user/root/profile"
PROFILE_ROLLBACK="nix profile rollback --profile /nix/var/nix/profiles/per-user/root/profile"
upgrading_lines() { grep -F "Upgrading the essentials profile" <<<"$1"; }

C="$(mktemp -d "$WORK/oe-upgrade.XXXXXX")"
oe_run "$C" useradd bare 0
eq "optional upgrade: status 0" 0 "$OE_RC"
eq "optional upgrade: the boot continues under errexit" yes "$OE_CONTINUED"
eq "optional upgrade: nothing on stderr" "" "$OE_ERR"
eq "optional upgrade: exactly two nix calls (remove, then install)" 2 "$(line_count "$C/nix.log")"
has "optional upgrade: the old bootstrap-essentials element is removed first" "$(sed -n 1p "$C/nix.log")" "$PROFILE_REMOVE"
has "optional upgrade: then the current bootstrap-essentials output is installed" "$(sed -n 2p "$C/nix.log")" "$PROFILE_INSTALL"
has "optional upgrade: the install names bootstrap-essentials" "$(sed -n 2p "$C/nix.log")" "#bootstrap-essentials"
eq "optional upgrade: both root nix calls run through run_root_nix (one hand-back each)" 2 "$(line_count "$C/handback.log")"
eq "optional upgrade: exactly one 'Upgrading the essentials profile' line" 1 "$(upgrading_lines "$OE_OUT" | grep -c .)"
has "optional upgrade: the line says the tool is optional" "$(upgrading_lines "$OE_OUT")" "optional"
has "optional upgrade: the line names 'nix-ld'" "$(upgrading_lines "$OE_OUT")" "'nix-ld'"
has "optional upgrade: the phase completes" "$OE_OUT" "Bootstrap phase: essentials installation completed in"
case "$OE_PATH" in
    /es/new/bin:*) test_pass "optional upgrade: PATH is re-resolved from the upgraded profile" ;;
    *) test_fail "optional upgrade: PATH is re-resolved from the upgraded profile (PATH=$OE_PATH)" ;;
esac

C="$(mktemp -d "$WORK/oe-fail.XXXXXX")"
oe_run "$C" useradd bare 1
eq "failed optional upgrade: status 0 (VS Code support is optional)" 0 "$OE_RC"
eq "failed optional upgrade: the boot continues under errexit" yes "$OE_CONTINUED"
has "failed optional upgrade: upgrade_essential_packages rolled the profile back" "$OE_NIX" "$PROFILE_ROLLBACK"
eq "failed optional upgrade: all three root nix calls run through run_root_nix (one hand-back each)" 3 "$(line_count "$C/handback.log")"
eq "failed optional upgrade: exactly one Warning line names nix-ld" 1 \
    "$(grep -F 'Warning:' <<<"$OE_ERR" | grep -Fc 'nix-ld')"
lacks "failed optional upgrade: no Error line" "$(grep '^Error:' <<<"$OE_OUT
$OE_ERR")" "Error:"
lacks "failed optional upgrade: the phase is not reported as failed" "$OE_OUT
$OE_ERR" "essentials installation failed"
has "failed optional upgrade: the phase still completes" "$OE_OUT" "Bootstrap phase: essentials installation completed in"

# The upgrade reports success, yet the profile still lacks nix-ld (e.g. a
# bootstrap flake without it): say so once, do not retry, keep booting.
C="$(mktemp -d "$WORK/oe-stillmissing.XXXXXX")"
oe_run "$C" useradd bare 0 no
eq "upgrade succeeded but nix-ld still missing: status 0" 0 "$OE_RC"
eq "upgrade succeeded but nix-ld still missing: the boot continues under errexit" yes "$OE_CONTINUED"
eq "upgrade succeeded but nix-ld still missing: one upgrade only (remove + install)" 2 "$(line_count "$C/nix.log")"
eq "upgrade succeeded but nix-ld still missing: exactly one Warning line names nix-ld" 1 \
    "$(grep -F 'Warning:' <<<"$OE_ERR" | grep -Fc 'nix-ld')"
eq "upgrade succeeded but nix-ld still missing: nothing else on stderr" 1 "$(line_count "$C/stderr")"
has "upgrade succeeded but nix-ld still missing: the phase still completes" "$OE_OUT" \
    "Bootstrap phase: essentials installation completed in"

C="$(mktemp -d "$WORK/oe-present.XXXXXX")"
oe_run "$C" useradd nixld
eq "nothing missing: status 0" 0 "$OE_RC"
eq "nothing missing: no nix call at all" "" "$OE_NIX"
eq "nothing missing: no hand-back" 0 "$(line_count "$C/handback.log")"
eq "nothing missing: no upgrade line" "" "$(upgrading_lines "$OE_OUT")"
eq "nothing missing: nothing on stderr" "" "$OE_ERR"
case "$OE_PATH" in
    /es/old/bin:*) test_pass "nothing missing: PATH keeps the profile resolved at the start" ;;
    *) test_fail "nothing missing: PATH keeps the profile resolved at the start (PATH=$OE_PATH)" ;;
esac

C="$(mktemp -d "$WORK/oe-onpath.XXXXXX")"
oe_run "$C" "useradd nix-ld" bare 0
has "nix-ld on PATH but not in the profile: the profile is still upgraded" "$OE_NIX" "$PROFILE_INSTALL"
has "nix-ld on PATH but not in the profile: the optional line names it" "$(upgrading_lines "$OE_OUT")" "'nix-ld'"

C="$(mktemp -d "$WORK/oe-noprofile.XXXXXX")"
oe_run "$C" useradd none
eq "no installed profile, required tools present: status 0" 0 "$OE_RC"
eq "no installed profile, required tools present: no nix call (never an optional upgrade)" "" "$OE_NIX"
eq "no installed profile, required tools present: no upgrade line" "" "$(upgrading_lines "$OE_OUT")"

C="$(mktemp -d "$WORK/oe-fresh.XXXXXX")"
oe_run "$C" "" none 0
eq "fresh install: status 0" 0 "$OE_RC"
eq "fresh install: exactly one nix call" 1 "$(line_count "$C/nix.log")"
has "fresh install: it is the normal install" "$OE_NIX" "$PROFILE_INSTALL"
has "fresh install: reported as before" "$OE_OUT" "Installing essential tools..."
lacks "fresh install: no optional upgrade" "$OE_OUT" "optional"

C="$(mktemp -d "$WORK/oe-required.XXXXXX")"
oe_run "$C" "" bare 0 no
eq "required upgrade: status 0" 0 "$OE_RC"
eq "required upgrade: one upgrade only (remove + install), even though nix-ld is still missing" 2 "$(line_count "$C/nix.log")"
eq "required upgrade: exactly one 'Upgrading the essentials profile' line" 1 "$(upgrading_lines "$OE_OUT" | grep -c .)"
has "required upgrade: the line names 'useradd'" "$(upgrading_lines "$OE_OUT")" "'useradd'"
lacks "required upgrade: no optional upgrade in the same boot" "$OE_OUT" "optional"

C="$(mktemp -d "$WORK/oe-required-fail.XXXXXX")"
oe_run "$C" "" bare 1
if [ "$OE_RC" -ne 0 ]; then
    test_pass "failed REQUIRED upgrade: install_essentials still fails the phase"
else
    test_fail "failed REQUIRED upgrade: install_essentials still fails the phase (status 0)"
fi
has "failed REQUIRED upgrade: the existing failure line" "$OE_ERR" "essentials installation failed"
lacks "failed REQUIRED upgrade: not reported as completed" "$OE_OUT" "completed in"
eq "failed REQUIRED upgrade: one install attempt only" 1 "$(grep -Fc "$PROFILE_INSTALL" "$C/nix.log")"

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
