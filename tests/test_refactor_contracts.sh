#!/bin/bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
failures=0
check() { if "$@"; then :; else echo "FAIL: $*" >&2; failures=$((failures + 1)); fi; }
reject() { ! "$@"; }

# Every library is import-only: no output and no caller control-state changes.
for library in "$ROOT"/bin/lib/*.sh "$ROOT"/container/aarch64-darwin-apple-container-dx-nixos-26.05/bootstrap/*.sh "$ROOT"/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/*.sh; do
    before_flags=$-; before_ifs=$IFS; before_pwd=$PWD; before_umask="$(umask)"; before_traps="$(trap -p)"
    # shellcheck source=/dev/null
    output="$(source "$library")"
    check test -z "$output"; check test "$before_flags" = "$-"; check test "$before_ifs" = "$IFS"; check test "$before_pwd" = "$PWD"; check test "$before_umask" = "$(umask)"; check test "$before_traps" = "$(trap -p)"
done

source "$ROOT/bin/lib/dx-config.sh"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-config-test.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
printf '%s\n' 'DX_CONTAINER_NAME=contract' 'DX_SSH_KEY=${DX_PROJECT_ROOT}/key' > "$fixture/good.env"
# DX_PROJECT_ROOT is read by dx_parse_config_file to expand the ${DX_PROJECT_ROOT}
# placeholder, which ShellCheck cannot see across the function boundary. Newer
# ShellCheck releases report SC2034 here; 0.10.0 does not.
# shellcheck disable=SC2034
DX_PROJECT_ROOT=$fixture
dx_parse_config_file "$fixture/good.env"
check test "$DXE_PARSED_DX_CONTAINER_NAME" = contract
check test "$DXE_PARSED_DX_SSH_KEY" = "$fixture/key"
printf '%s\n' 'DX_CONTAINER_NAME=$(touch /tmp/never)' > "$fixture/hostile.env"
check reject dx_parse_config_file "$fixture/hostile.env"

source "$ROOT/bin/lib/dx-mount-plan.sh"
check test "$(dx_mount_legacy_decode_value '/tmp/a\ b')" = '/tmp/a b'
check test "$(dx_mount_legacy_decode_value "\$'/tmp/a\\nb'")" = $'/tmp/a\nb'
check reject dx_mount_legacy_decode_value '$(id)'

source "$ROOT/bin/lib/dx-host-util.sh"
source "$ROOT/bin/lib/dx-tunnel.sh"
check dx_tunnel_validate_port 1024 host false
check reject dx_tunnel_validate_port 80 host false

source "$ROOT/bin/lib/dx-container.sh"
container() { case "$*" in 'image list --quiet') printf '%s\n' contract-image:latest ;; *) return 1 ;; esac; }
check container_image_exists contract-image
check reject container_image_exists absent-image

source "$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-keyring.sh"
check dx_keyring_address_valid unix:path=/tmp/dbus-test
check reject dx_keyring_address_valid not-an-address
legacy_keyring="$fixture/legacy-keyring.env"
printf "%s\n" "export DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/dbus-test'" > "$legacy_keyring"
check test "$(dx_keyring_read_legacy_env "$legacy_keyring")" = unix:path=/tmp/dbus-test
printf "%s\n" "export DBUS_SESSION_BUS_ADDRESS='unix:path=/tmp/dbus-test'; touch '$fixture/executed'" > "$legacy_keyring"
check reject dx_keyring_read_legacy_env "$legacy_keyring"
check test ! -e "$fixture/executed"
address_file="$fixture/keyring/keyring-address"
check dx_keyring_write_address "$address_file" unix:path=/tmp/dbus-test
check test "$(dx_keyring_read_address "$address_file")" = unix:path=/tmp/dbus-test
printf 'unix:path=/tmp/dbus-test\n\n' > "$address_file"
check reject dx_keyring_read_address "$address_file"

# --- B2 contract: run_all_tests.sh dispatches every section exactly once,
# and never orphans a test file. This is the class of bug where the Herdr
# refactor silently dropped test_bootstrap_publication.sh's dispatch entry
# while renumbering sections around it: KNOWN_SECTIONS still "knew" about
# every number, but no run_test call named the file any more.
contains_word() {
    local needle="$1" haystack="$2"
    case " $haystack " in
        *" $needle "*) return 0 ;;
        *) return 1 ;;
    esac
}

runner="$ROOT/tests/run_all_tests.sh"
known_sections="$(sed -n 's/^KNOWN_SECTIONS="\(.*\)"$/\1/p' "$runner")"
dispatch_lines="$(grep -E 'run_test[[:space:]]+"\$SCRIPT_DIR/[^"]+"[[:space:]]+"[0-9]+"' "$runner")"
dispatch_files="$(printf '%s\n' "$dispatch_lines" | sed -E 's/.*\$SCRIPT_DIR\/([^"]+)".*/\1/' | tr '\n' ' ')"
dispatch_numbers="$(printf '%s\n' "$dispatch_lines" | sed -E 's/.*"([0-9]+)"[[:space:]]*$/\1/' | tr '\n' ' ')"

# Every KNOWN_SECTIONS number must be dispatched exactly once...
for section_number in $known_sections; do
    dispatch_count="$(printf '%s\n' "$dispatch_numbers" | tr ' ' '\n' | grep -c "^$section_number\$" || true)"
    check test "$dispatch_count" -eq 1
done
# ...and no run_test entry may use a number KNOWN_SECTIONS doesn't list.
for section_number in $dispatch_numbers; do
    check contains_word "$section_number" "$known_sections"
done

# Every tests/test_section*.sh file, plus the other suites run_all_tests.sh
# dispatches (test_refactor_state_machines.sh, test_bootstrap_publication.sh),
# must have a run_test entry — this is precisely what test_bootstrap_publication.sh lost.
expected_suites="$(cd "$ROOT/tests" && ls test_section*.sh | tr '\n' ' ') test_refactor_state_machines.sh test_bootstrap_publication.sh"
for suite in $expected_suites; do
    check contains_word "$suite" "$dispatch_files"
done

# --- F6 self-test: the fixed idiom for subshell-isolated assertions must
# still be able to fail the suite. Before the fix, test_pass/test_fail called
# *inside* a `( … )` subshell incremented counters that die with the
# subshell — a real failure inside one was silently discarded, e.g.
# `( test_fail "boom" ); print_summary; exit_with_code` prints "0 failed" and
# exits 0. This proves the replacement pattern — evaluate the condition
# inside the subshell, branch on its exit status, call test_pass/test_fail in
# the parent — correctly fails the run when the subshell's condition is false,
# so this regression cannot return silently.
if ROOT="$ROOT" bash -c '
    set -euo pipefail
    source "$ROOT/tests/test_helpers.sh"
    if ( set -e; false ); then test_pass "probe"; else test_fail "probe"; fi
    print_summary >/dev/null
    exit_with_code
' >/dev/null 2>&1; then
    probe_status=0
else
    probe_status=$?
fi
check test "$probe_status" -ne 0

# --- F13 contract: DX_AI_TOOLS is no longer just an inventory to keep tidy,
# it is load-bearing. dx_ai_validate_generation requires an executable of that
# name in every published generation's profile, and dx_ai_verify runs
# `command -v` over the same list, so a name added there without a matching
# package in flake.nix's aiPackages makes *every* generation fail validation
# and every dx-ai run fail at verification. That is a worse failure mode than
# the cosmetic duplication F13 described, and nothing tied the two together.
#
# The two lists cannot be compared verbatim -- these are binary names, not Nix
# attribute names (`claude` ships in `claude-code`, `gemini` in `gemini-cli`).
# The contract asserted is the one that catches the real mistake: every tool
# dx-ai will demand has *some* package whose attribute name starts with it.
container_dir="$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05"
declared_tools="$(sed -n 's/^DX_AI_TOOLS="\(.*\)"$/\1/p' "$container_dir/scripts/dx-ai.sh")"
check test -n "$declared_tools"
ai_packages="$(sed -n '/aiPackages = /,/^[[:space:]]*\];$/p' "$container_dir/flake.nix" | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9_.-]*\)$/\1/p')"
has_package_for() {
    local tool="$1" package
    for package in $ai_packages; do
        case "${package#pkgs.}" in "$tool"|"$tool"-*) return 0 ;; esac
    done
    return 1
}
for tool in $declared_tools; do
    check has_package_for "$tool"
done

# The user-facing install message in bin/dx-herdr names the bundle's contents.
# It is the one copy of the inventory a user actually reads before waiting
# ~2 minutes for an install, so it must not drift from what is installed.
herdr_message_tools="$(sed -n 's/.*Installing optional AI tools bundle (\([^)]*\)).*/\1/p' "$ROOT/bin/dx-herdr" | tr -d ',')"
check test "$herdr_message_tools" = "$declared_tools"

# The SIGPIPE behavior probe deliberately lives in Section 9 rather than here.
# This file runs under kcov, and kcov's bash instrumentation leaves BASH_SOURCE
# unset inside a nested `bash -c`, so sourcing test_helpers.sh from one dies on
# `set -u` before reaching the assertion. Section 9 sources the helpers
# normally and is not part of the coverage run.
#
# The same defect in a different shape: `tar -cf - | ... tar -xf -`. tar stops
# at the end-of-archive marker without necessarily draining the creator's
# trailing padding, so the creator takes EPIPE and pipefail fails a complete,
# correct publication. bin/dx-sync-bootstrap's guest script must therefore
# consume its input to the end after extracting.
check grep -q 'cat >/dev/null' "$ROOT/bin/dx-sync-bootstrap"

# --- The bootstrap essentials closure is the guest's entire pre-sshd
# dependency set, and since it moved out of the bootstrap scripts into
# flake.nix's `bootstrapEssentials` it is declared in exactly one place.
# A tidy-up of that list ("coreutils surely provides tar") has nothing else
# standing between it and a guest that dies before sshd -- the failure class
# this whole change exists to prevent.
#
# The binary -> nixpkgs attribute mapping is the part that is easy to get
# wrong: tar is gnutar, useradd is shadow, mkfs.btrfs is btrfs-progs. Assert
# it in both directions -- the providing package is still declared, and the
# binary is still genuinely invoked by bootstrap -- so a stale entry here gets
# reported rather than left silently guarding nothing.
#
# Packages in the list that bootstrap never invokes (gzip, procps, which,
# sudo) are deliberately not asserted: they serve the dx user's shell after
# boot rather than bootstrap itself.
bootstrap_essentials="$(sed -n '/bootstrapEssentials = /,/^[[:space:]]*\];$/p' "$container_dir/flake.nix" | sed -n 's/^[[:space:]]*\([A-Za-z][A-Za-z0-9_.-]*\)$/\1/p')"
check test -n "$bootstrap_essentials"
bootstrap_sources=("$container_dir/bootstrap.sh" "$container_dir"/bootstrap/*.sh)
# Full-line comments are stripped so a binary named only in prose cannot stand
# in for a real invocation. `-Fw` rather than an anchored ERE: word-matching a
# fixed string is exactly the intent, and it avoids the `(^|[^[:alnum:]...])`
# construct that some grep builds (ugrep) silently fail to match.
#
# The stripped text is materialized once and matched from a herestring rather
# than piped: `grep -q` exits at the first match, and under `set -o pipefail`
# the resulting EPIPE in the upstream `sed` would fail every *successful*
# lookup -- the same SIGPIPE-under-pipefail defect described at the end of
# this file.
bootstrap_source_text="$(sed 's/^[[:space:]]*#.*//' "${bootstrap_sources[@]}")"
bootstrap_invokes() { grep -Fqw "$1" <<<"$bootstrap_source_text"; }
bootstrap_declares() {
    local declared
    for declared in $bootstrap_essentials; do
        [ "$declared" = "$1" ] && return 0
    done
    return 1
}
for pair in useradd:shadow groupadd:shadow usermod:shadow ssh-keygen:openssh \
    sshd:openssh tar:gnutar mount:util-linux sed:gnused grep:gnugrep \
    chown:coreutils mktemp:coreutils stat:coreutils mkfs.btrfs:btrfs-progs \
    mkfs.ext4:e2fsprogs bash:bashInteractive; do
    check bootstrap_declares "${pair##*:}"
    check bootstrap_invokes "${pair%%:*}"
done

[ "$failures" -eq 0 ]
