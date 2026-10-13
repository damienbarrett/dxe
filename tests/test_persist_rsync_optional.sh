#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
set -uo pipefail

# WP6.2c (plans/do plan.md, progress log "Gap found by the WP1.4 author" and
# D-10): rsync joins the best-effort optional essentials list so an EXISTING
# guest (e.g. the production QNAP guest) receives it on its next boot, before
# a migration. WP6.2b's rsync_check refuses with "boot the guest once ...
# include rsync" when the nix volume's root profile lacks bin/rsync.
#
# Contract (extends WP1.4's tests/test_persist_vscode_server.sh, which stays
# untouched):
#  - essentials_optional_tools lists 'nix-ld libexec/nix-ld' first and
#    'rsync bin/rsync' second (nix-ld keeps its priority: it was first, and
#    the list is priority order), each exactly once.
#  - An installed root profile with nix-ld but no bin/rsync (a dangling link
#    counts) makes essentials_first_missing_optional_tool print `rsync`.
#  - install_essentials then runs the best-effort upgrade (remove, then
#    install) with one "Upgrading the essentials profile ... optional ...
#    'rsync'" line; a failed upgrade warns naming rsync and the boot goes on.
#  - Nothing missing: no nix call. All fixtures live under DX_ESSENTIALS_ROOT
#    in a temporary directory; `nix` is a recording function (never a real
#    profile) and the fail-closed fake tool directory sits on PATH.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP6.2c: rsync is an optional essentials tool"

# shellcheck source=../container/dx-nixos-26.05/bootstrap/common.sh
source "$CONTAINER_DIR/bootstrap/common.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/system.sh
source "$CONTAINER_DIR/bootstrap/system.sh"
# shellcheck source=../container/dx-nixos-26.05/bootstrap/base-and-storage.sh
source "$CONTAINER_DIR/bootstrap/base-and-storage.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

umask 022
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dxe-rsync-optional.XXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)" || exit 1
case "$WORK" in
    /*/dxe-rsync-optional.*) : ;;
    *) echo "unexpected scratch dir [$WORK]" >&2; exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

eq() { # LABEL EXPECTED ACTUAL
    if [ "$2" = "$3" ]; then test_pass "$1"; else test_fail "$1 (expected [$2], got [$3])"; fi
}
has() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_pass "$1"; else test_fail "$1 (no [$3] in [$2])"; fi
}
lacks() { # LABEL TEXT NEEDLE
    if grep -Fq -- "$3" <<<"$2"; then test_fail "$1 (found [$3] in [$2])"; else test_pass "$1"; fi
}
line_count() { # FILE
    if [ -f "$1" ]; then awk 'END { print NR }' "$1"; else echo 0; fi
}

# rp_profile ROOT KIND -- an installed per-user root profile under ROOT.
# KIND: both (nix-ld and rsync), nixld (nix-ld only), dangling (nix-ld
# present, bin/rsync a dangling link), neither.
rp_profile() {
    local root="$1" kind="$2" gen="$1/nix/store/8888hhhh-profile" profiles="$1/nix/var/nix/profiles/per-user/root"
    local nixld="$1/nix/store/1111aaaa-nix-ld-2.0.6" rsync="$1/nix/store/2222bbbb-rsync-3.4.1"
    mkdir -p "$gen/bin" "$gen/libexec" "$profiles" "$nixld/bin" "$rsync/bin"
    ln -s "$gen" "$profiles/profile-1-link"
    ln -s profile-1-link "$profiles/profile"
    printf 'fake nix-ld\n' > "$nixld/bin/nix-ld"
    printf 'fake rsync\n' > "$rsync/bin/rsync"
    case "$kind" in
        both) ln -s "$nixld/bin/nix-ld" "$gen/libexec/nix-ld"; ln -s "$rsync/bin/rsync" "$gen/bin/rsync" ;;
        nixld) ln -s "$nixld/bin/nix-ld" "$gen/libexec/nix-ld" ;;
        dangling) ln -s "$nixld/bin/nix-ld" "$gen/libexec/nix-ld"; ln -s "$root/nix/store/0000gone-rsync/bin/rsync" "$gen/bin/rsync" ;;
        *) : ;;
    esac
}

# rp_find KIND -- essentials_first_missing_optional_tool against a new fixture.
rp_find() {
    local r
    r="$(mktemp -d "$WORK/find-$1.XXXXXX")"
    rp_profile "$r/root" "$1"
    RP_OUT="$( (
        DX_ESSENTIALS_ROOT="$r/root"
        export DX_ESSENTIALS_ROOT
        essentials_first_missing_optional_tool
    ) 2>&1)"
    RP_RC=$?
}

LIST="$(essentials_optional_tools 2>/dev/null)"
eq "the optional list holds 'nix-ld libexec/nix-ld' exactly once" 1 "$(grep -Fxc 'nix-ld libexec/nix-ld' <<<"$LIST")"
eq "the optional list holds 'rsync bin/rsync' exactly once" 1 "$(grep -Fxc 'rsync bin/rsync' <<<"$LIST")"
eq "nix-ld keeps priority: it is listed before rsync" "nix-ld rsync" "$(awk '{ print $1 }' <<<"$LIST" | tr '\n' ' ' | sed 's/ $//')"

rp_find nixld
eq "nix-ld present, bin/rsync absent: reports rsync" "rsync" "$RP_OUT"
eq "nix-ld present, bin/rsync absent: status 0" 0 "$RP_RC"
rp_find dangling
eq "a dangling bin/rsync counts as missing" "rsync" "$RP_OUT"
rp_find neither
eq "neither present: nix-ld is reported first" "nix-ld" "$RP_OUT"
rp_find both
eq "both present: nothing reported" "" "$RP_OUT"
eq "both present: status 1" 1 "$RP_RC"

# ---------------------------------------------------------------------------
test_section "WP6.2c: install_essentials upgrades an existing profile for rsync, best effort"

FAIL_CLOSED="$(fake_tool_dir_create "$WORK")"
PROFILE_REMOVE="nix profile remove --profile /nix/var/nix/profiles/per-user/root/profile bootstrap-essentials"
PROFILE_INSTALL="nix profile install --profile /nix/var/nix/profiles/per-user/root/profile"
PROFILE_ROLLBACK="nix profile rollback --profile /nix/var/nix/profiles/per-user/root/profile"
upgrading_lines() { grep -F "Upgrading the essentials profile" <<<"$1"; }

# rp_run DIR KIND INSTALL_RC -- install_essentials under bootstrap's shell
# options with the required tools present; the recording `nix` stub logs
# every call and, on a successful install, adds bin/rsync to the generation.
rp_run() {
    local dir="$1" kind="$2" install_rc="${3:-0}" root="$1/es-root" gen="$1/es-root/nix/store/8888hhhh-profile"
    rp_profile "$root" "$kind"
    : > "$dir/nix.log"
    : > "$dir/handback.log"
    rm -f "$dir/upgraded" "$dir/continued"
    (
        set -euo pipefail
        PATH="$FAIL_CLOSED:$PATH"
        DX_ESSENTIALS_ROOT="$root"
        export DX_ESSENTIALS_ROOT
        unset DX_USAGE_SERVICE
        command() {
            if [ "${1:-}" = -v ]; then printf '/fake/bin/%s\n' "${2:-}"; return 0; fi
            builtin command "$@"
        }
        essentials_profile_path() {
            if [ -e "$dir/upgraded" ]; then printf '%s\n' /es/new/bin; else printf '%s\n' /es/old/bin; fi
        }
        # int-4 (main's fix/gc-rootpaths): run_root_nix hands root-owned store
        # paths back after every root nix call, with the guest's GNU stat,
        # find and chown; tests/test_bootstrap_nix_rootpaths*.sh hold that
        # behaviour. Record each hand-back here instead of running it on
        # this fixture.
        hand_back_root_nix_paths() { printf 'hand-back\n' >> "$dir/handback.log"; }
        nix() {
            printf 'nix %s\n' "$*" >> "$dir/nix.log"
            case "$*" in
                *"profile install"*)
                    if [ "$install_rc" -eq 0 ]; then
                        : > "$dir/upgraded"
                        printf 'fake rsync\n' > "$gen/bin/rsync"
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
    RP_RC=$?
    RP_OUT="$(cat "$dir/stdout")"
    RP_ERR="$(cat "$dir/stderr")"
    RP_NIX="$(cat "$dir/nix.log")"
    RP_PATH="$(cat "$dir/path" 2>/dev/null)"
    RP_CONTINUED=no
    if [ -f "$dir/continued" ]; then RP_CONTINUED=yes; fi
}

C="$(mktemp -d "$WORK/up.XXXXXX")"
rp_run "$C" nixld 0
eq "rsync upgrade: status 0" 0 "$RP_RC"
eq "rsync upgrade: the boot continues under errexit" yes "$RP_CONTINUED"
eq "rsync upgrade: nothing on stderr" "" "$RP_ERR"
eq "rsync upgrade: exactly two nix calls (remove, then install)" 2 "$(line_count "$C/nix.log")"
has "rsync upgrade: the old element is removed first" "$(sed -n 1p "$C/nix.log")" "$PROFILE_REMOVE"
has "rsync upgrade: then the current output is installed" "$(sed -n 2p "$C/nix.log")" "$PROFILE_INSTALL"
eq "rsync upgrade: both root nix calls run through run_root_nix (one hand-back each)" 2 "$(line_count "$C/handback.log")"
eq "rsync upgrade: exactly one 'Upgrading the essentials profile' line" 1 "$(upgrading_lines "$RP_OUT" | grep -c .)"
has "rsync upgrade: the line says the tool is optional" "$(upgrading_lines "$RP_OUT")" "optional"
has "rsync upgrade: the line names 'rsync'" "$(upgrading_lines "$RP_OUT")" "'rsync'"
lacks "rsync upgrade: the line does not name nix-ld" "$(upgrading_lines "$RP_OUT")" "nix-ld"
has "rsync upgrade: the phase completes" "$RP_OUT" "Bootstrap phase: essentials installation completed in"
case "$RP_PATH" in
    /es/new/bin:*) test_pass "rsync upgrade: PATH is re-resolved from the upgraded profile" ;;
    *) test_fail "rsync upgrade: PATH is re-resolved from the upgraded profile (PATH=$RP_PATH)" ;;
esac

C="$(mktemp -d "$WORK/fail.XXXXXX")"
rp_run "$C" nixld 1
eq "failed rsync upgrade: status 0 (rsync is optional)" 0 "$RP_RC"
eq "failed rsync upgrade: the boot continues under errexit" yes "$RP_CONTINUED"
has "failed rsync upgrade: the profile was rolled back" "$RP_NIX" "$PROFILE_ROLLBACK"
eq "failed rsync upgrade: all three root nix calls run through run_root_nix (one hand-back each)" 3 "$(line_count "$C/handback.log")"
eq "failed rsync upgrade: exactly one Warning line names rsync" 1 \
    "$(grep -F 'Warning:' <<<"$RP_ERR" | grep -Fc 'rsync')"
lacks "failed rsync upgrade: no Error line" "$(grep '^Error:' <<<"$RP_OUT
$RP_ERR")" "Error:"
has "failed rsync upgrade: the phase still completes" "$RP_OUT" "Bootstrap phase: essentials installation completed in"

C="$(mktemp -d "$WORK/none.XXXXXX")"
rp_run "$C" both 0
eq "nothing missing: status 0" 0 "$RP_RC"
eq "nothing missing: no nix call" "" "$RP_NIX"
eq "nothing missing: no hand-back" 0 "$(line_count "$C/handback.log")"
eq "nothing missing: no upgrade line" "" "$(upgrading_lines "$RP_OUT")"

print_summary
exit_with_code
