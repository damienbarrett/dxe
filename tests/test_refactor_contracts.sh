#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
container_dir="$ROOT/container/aarch64-darwin-apple-container-dx-nixos-26.05"
failures=0
check() { if "$@"; then :; else echo "FAIL: $*" >&2; failures=$((failures + 1)); fi; }
reject() { ! "$@"; }

# Every library is import-only: no output on stdout or stderr, a zero exit
# status, and no caller control-state changes.
#
# The host's /bin/bash is 3.2, which lacks Bash 4's `declare -A`. Sourcing a
# guest library that uses it (e.g. bootstrap/herdr-config.sh) prints
# "invalid option" diagnostics to stderr but still returns status 0, so a
# check that only looked at stdout (as this one used to) saw nothing wrong.
# Rather than let that pass silently, only the host libraries that actually
# run under 3.2 are checked there; the guest libraries get the identical
# strict check under Bash 5, which this file also runs under via
# tests/run-coverage-linux.sh -> run-coverage-contracts.sh.
libraries=("$ROOT"/bin/lib/*.sh)
if [ "${BASH_VERSINFO[0]}" -ge 4 ]; then
    libraries+=("$container_dir"/bootstrap/*.sh "$container_dir"/scripts/lib/*.sh)
fi
# WP1.6 (Fable D4): the same import-purity bar applies to the test
# harness's own sourceable libraries, not only to production -- a helper
# that fails the check it enforces on bin/lib/*.sh is exactly the gap D4
# found. tests/lib/*.sh is NOT globbed wholesale: tests/lib/audit-flake-
# lock.sh is a standalone CLI tool (`set -euo pipefail`, three required
# positional arguments, `exit 2` on a bad invocation) that is always
# exec'd -- never sourced -- anywhere in this repository, so sourcing it
# here would fail for a reason that has nothing to do with import purity.
libraries+=(
    "$ROOT/tests/lib/harness.sh"
    "$ROOT/tests/lib/fake-tools.sh"
    "$ROOT/tests/lib/tmux-probes.sh"
    "$ROOT/tests/lib/coverage-metric.sh"
    "$ROOT/tests/test_helpers.sh"
)

# --- GREEN (WP1.6 / Fable D4): a real-subprocess probe -------------------
#
# The previous idiom, `output="$(source "$library" ...)"`, sources the
# library inside the command substitution's OWN forked subshell: that
# subshell inherits this process's $-/IFS/PWD/umask/traps/SCRIPT_DIR at
# fork time, but anything the sourced library does to ITS OWN copies of
# those dies with the subshell the instant the substitution finishes -- it
# can never reach an "after" comparison read from this process's own,
# still-untouched values. Verified empirically by the two fixtures below.
#
# The fix sources the library inside a REAL, SEPARATE PROCESS instead: a
# probe FILE run via `bash "$probe" ...`, never an inline `bash -c '...'`.
# This file runs under kcov in CI, and kcov's bash instrumentation sets PS4
# to a trace string that expands ${BASH_SOURCE}, which is unset inside a
# `bash -c` program, so under `set -u` the probe would die on
# "BASH_SOURCE: unbound variable" before ever reaching `source` -- a real
# file gives bash a real BASH_SOURCE and sidesteps that entirely (the same
# reasoning entrypoint_conforms and the F6 self-test below already apply).
# Before/after state is captured INSIDE that one process, on either side of
# the `source` call, and written to a result file -- which, unlike the old
# subshell's exit-time state, survives the probe process's own exit for
# THIS file to read back and compare, one property at a time.
#
# The probe process's own exit status is the library's `source` exit
# status (an explicit `exit "$source_status"` as its last line), not
# whatever the trailing `printf`s would otherwise leave behind -- so a
# library that fails without calling `exit` is still caught by the
# `status -eq 0` check below exactly as it was under the old idiom. A
# library that DOES call `exit` terminates the probe process before the
# "after" block ever runs, leaving those fields absent from the result
# file -- read back as empty strings, which correctly fail every affected
# before/after comparison rather than silently reusing a stale value.
purity_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-purity-probe.XXXXXX")"
purity_probe_script="$purity_probe_dir/probe.sh"
cat > "$purity_probe_script" <<'PROBE'
#!/bin/bash
library="$1"
result_file="$2"
# A pinned canary, not the caller's ambient value: every real caller in
# this repository already sets SCRIPT_DIR to the same directory a library
# like tests/test_helpers.sh then reassigns it to, so a before/after diff
# of the ambient value would coincide even when the library clobbers it.
# A sentinel makes the clobber visible regardless of what a caller had.
SCRIPT_DIR="dxe-purity-canary"
{
    printf 'flags_before=%s\n' "$-"
    printf 'ifs_before=%s\n' "$IFS"
    printf 'pwd_before=%s\n' "$PWD"
    printf 'umask_before=%s\n' "$(umask)"
    printf 'traps_before=%s\n' "$(trap -p)"
    printf 'script_dir_before=%s\n' "$SCRIPT_DIR"
} > "$result_file"
# shellcheck source=/dev/null
source "$library"
source_status=$?
{
    printf 'flags_after=%s\n' "$-"
    printf 'ifs_after=%s\n' "$IFS"
    printf 'pwd_after=%s\n' "$PWD"
    printf 'umask_after=%s\n' "$(umask)"
    printf 'traps_after=%s\n' "$(trap -p)"
    printf 'script_dir_after=%s\n' "$SCRIPT_DIR"
} >> "$result_file"
exit "$source_status"
PROBE

# purity_field NAME RESULT_FILE -- NAME's recorded value, or an empty
# string if the probe process never reached the line that would have
# written it.
purity_field() { sed -n "s/^$1=//p" "$2" | tail -n1; }

# purity_probe_run LIBRARY OUT ERR RESULT -- runs the probe above against
# LIBRARY in a fresh process, stdin from /dev/null (an interactive `read`
# in a library that should be import-only fails closed instead of
# blocking), stdout/stderr captured to OUT/ERR, before/after state written
# to RESULT. Returns the probe's own exit status (the library's `source`
# status) via $?; callers use the `&& status=0 || status=$?` idiom so a
# non-zero status here never trips this file's own `set -e`.
purity_probe_run() {
    local library="$1" out="$2" err="$3" result="$4"
    bash "$purity_probe_script" "$library" "$result" </dev/null >"$out" 2>"$err"
}

# purity_clean LIBRARY -- true if LIBRARY passes the full eight-way
# import-only contract (no stdout, no stderr, a zero exit status, and
# $-/IFS/PWD/umask/traps/SCRIPT_DIR unchanged across the source).
purity_clean() {
    local library="$1"
    local out err result status ok
    out="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-out.XXXXXX")"
    err="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-err.XXXXXX")"
    result="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-result.XXXXXX")"
    purity_probe_run "$library" "$out" "$err" "$result" && status=0 || status=$?
    ok=1
    [ -s "$out" ] && ok=0
    [ -s "$err" ] && ok=0
    [ "$status" -eq 0 ] || ok=0
    [ "$(purity_field flags_before "$result")" = "$(purity_field flags_after "$result")" ] || ok=0
    [ "$(purity_field ifs_before "$result")" = "$(purity_field ifs_after "$result")" ] || ok=0
    [ "$(purity_field pwd_before "$result")" = "$(purity_field pwd_after "$result")" ] || ok=0
    [ "$(purity_field umask_before "$result")" = "$(purity_field umask_after "$result")" ] || ok=0
    [ "$(purity_field traps_before "$result")" = "$(purity_field traps_after "$result")" ] || ok=0
    [ "$(purity_field script_dir_before "$result")" = "$(purity_field script_dir_after "$result")" ] || ok=0
    rm -f "$out" "$err" "$result"
    [ "$ok" -eq 1 ]
}

# Self-proof before the real scan is trusted (the same discipline the leak
# and bare-sleep scans below apply to themselves): a real violation must be
# caught, and a genuinely pure library must not be flagged.
purity_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-purity-fixture.XXXXXX")"
cat > "$purity_fixture_dir/impure.sh" <<'EOF'
#!/bin/bash
set -u
SCRIPT_DIR="clobbered-by-fixture"
EOF
cat > "$purity_fixture_dir/pure.sh" <<'EOF'
#!/bin/bash
# A pure fixture: only a function definition, no side effects at source time.
dxe_purity_fixture_pure_noop() { :; }
EOF
check reject purity_clean "$purity_fixture_dir/impure.sh"
check purity_clean "$purity_fixture_dir/pure.sh"
rm -rf "$purity_fixture_dir"

# The real gate: every library above must be import-only. One `check` per
# property (not a single aggregate condition), so a violation is
# attributable to a specific property instead of collapsing into one
# opaque failure.
for library in "${libraries[@]}"; do
    purity_out="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-out.XXXXXX")"
    purity_err="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-err.XXXXXX")"
    purity_result="$(mktemp "${TMPDIR:-/tmp}/dxe-purity-result.XXXXXX")"
    purity_probe_run "$library" "$purity_out" "$purity_err" "$purity_result" && purity_status=0 || purity_status=$?
    purity_output="$(cat "$purity_out")"
    purity_stderr_output="$(cat "$purity_err")"
    check test -z "$purity_output"; check test -z "$purity_stderr_output"; check test "$purity_status" -eq 0
    check test "$(purity_field flags_before "$purity_result")" = "$(purity_field flags_after "$purity_result")"
    check test "$(purity_field ifs_before "$purity_result")" = "$(purity_field ifs_after "$purity_result")"
    check test "$(purity_field pwd_before "$purity_result")" = "$(purity_field pwd_after "$purity_result")"
    check test "$(purity_field umask_before "$purity_result")" = "$(purity_field umask_after "$purity_result")"
    check test "$(purity_field traps_before "$purity_result")" = "$(purity_field traps_after "$purity_result")"
    check test "$(purity_field script_dir_before "$purity_result")" = "$(purity_field script_dir_after "$purity_result")"
    rm -f "$purity_out" "$purity_err" "$purity_result"
done
rm -rf "$purity_probe_dir"

# WP1.6 (Fable D4): the helper may not source production code. It used to
# source bin/lib/dx-host-util.sh before any assertion helper existed to
# prove the import was otherwise inert; a suite that needs one of its
# functions now sources it directly instead.
check reject grep -q 'bin/lib' "$ROOT/tests/test_helpers.sh"

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
# WP1.8 (Fable D6): scope the fake to exactly the two checks above -- this
# file's own leaking-override contract (below) would otherwise flag it.
unset -f container

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
#
# The probe runs as a real file for the same reason entrypoint_conforms's
# probe does below: this file runs under kcov in CI, and kcov's bash
# instrumentation sets PS4 to a trace string that expands `${BASH_SOURCE}`,
# which is unset inside an inline `bash -c '...'` program, so under `set -u`
# the probe used to die on `BASH_SOURCE: unbound variable` before ever
# sourcing test_helpers.sh -- and a probe that crashes for the wrong reason
# still exits non-zero, so the plain exit-status check below used to pass
# vacuously under kcov. Asserting the stripped summary line names exactly
# "1 failed" closes that gap: only a real, single test_fail can produce it.
f6_probe_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-f6-probe.XXXXXX")"
f6_probe_script="$f6_probe_dir/probe.sh"
cat > "$f6_probe_script" <<'PROBE'
#!/bin/bash
set -euo pipefail
source "$ROOT/tests/test_helpers.sh"
if ( set -e; false ); then test_pass "probe"; else test_fail "probe"; fi
print_summary
exit_with_code
PROBE
f6_probe_output="$(ROOT="$ROOT" bash "$f6_probe_script" 2>&1)" && f6_probe_status=0 || f6_probe_status=$?
rm -rf "$f6_probe_dir"
check test "$f6_probe_status" -ne 0
f6_probe_summary="$(sed 's/\x1b\[[0-9;]*m//g' <<<"$f6_probe_output")"
f6_summary_reports_one_failed() { grep -q '1 failed' <<<"$f6_probe_summary"; }
check f6_summary_reports_one_failed

# WP8.4b (Fable D7): the DX_AI_TOOLS/aiPackages tie (the old "F13 contract")
# moved to tests/test_contracts_source.sh, alongside the other reviewed
# source-text contracts.

# The SIGPIPE behavior probe deliberately lives in Section 9 rather than here.
# This file runs under kcov, and kcov's bash instrumentation leaves BASH_SOURCE
# unset inside a nested `bash -c`, so sourcing test_helpers.sh from one dies on
# `set -u` before reaching the assertion. Section 9 sources the helpers
# normally and is not part of the coverage run.
#
# The same defect in a different shape: `tar -cf - | ... tar -xf -`. tar stops
# at the end-of-archive marker without necessarily draining the creator's
# trailing padding, so the creator takes EPIPE and pipefail fails a complete,
# correct publication. WP5.1 (Fable A2) moved this pipeline out of
# bin/dx-sync-bootstrap and into bin/lib/dx-bootstrap-sync.sh's
# dx_bootstrap_sync (the `tar -cf - . | dx_runtime_exec -i "$container" sh -c
# '...'` call and its embedded guest script), so the drain must be asserted
# there now -- pinning the entrypoint would pass even if the guest script
# stopped draining its input, since the string no longer has to appear there
# at all.
check grep -q 'cat >/dev/null' "$ROOT/bin/lib/dx-bootstrap-sync.sh"

# WP8.4b (Fable D7): the bootstrapEssentials tie (binary <-> nixpkgs
# attribute, both directions) and the Branch 16 "no keyring knowledge in
# bootstrap" check moved to tests/test_contracts_source.sh, alongside the
# other reviewed source-text contracts.

# --- WP4.1 (Fable A4 / Muse A1): every bin/dx* entrypoint except dx-lib.sh
# (a library) must be safely sourceable -- no output, exit 0, and a defined
# `<name>_main` function -- rather than running its whole body at import
# time. Only dx-forward and dx-reverse conform today
# (`if [ "${BASH_SOURCE[0]}" = "$0" ]; then forward_main "$@"; fi`,
# dx-forward:44); every other entrypoint still executes unconditionally on
# source, so this probe can never source one directly in this process --
# that would touch the real container runtime, write a real SSH keypair, or
# block on a real tty. Each entrypoint is instead copied into its own
# private "project root" (DX_SSH_KEY and friends resolve from
# DX_PROJECT_ROOT, which bin/dx-lib.sh always recomputes from the sourced
# file's own location -- a fake HOME alone would not stop dx-create-keys
# from writing a real keypair into this checkout), sourced by a nested probe
# script with HOME and XDG_STATE_HOME redirected into that same private
# root, PATH restricted to a directory holding only fake
# `container`/`docker`/`ssh` (each `exit 1`) plus /usr/bin:/bin, and stdin
# from /dev/null so a script that reaches an interactive `read` fails closed
# instead of blocking. `timeout` is not on macOS, so a backgrounded subshell
# plus a 20s watchdog `kill -9` stands in for it: a mis-guarded script can
# hang or fail, but it cannot hang this suite or mutate anything outside its
# own scratch directory.
#
# The nested probe is a real file (`$probe_root/probe.sh`, run as `bash
# "$probe_root/probe.sh" ...`), not an inline `bash -c '...'` program:
# kcov's bash instrumentation (this file runs under kcov in CI) sets PS4 to
# a trace string that expands `${BASH_SOURCE}`, which is an empty array
# inside a `bash -c` program, so under `set -u` the nested shell dies on
# `BASH_SOURCE: unbound variable` before it ever reaches `source`. A real
# file gives bash a real BASH_SOURCE and sidesteps that entirely.
entrypoint_main_name() {
    local base="$1" name
    name=${base#dx}
    name=${name#-}
    [ -n "$name" ] || name=dx
    name=${name//-/_}
    printf '%s_main' "$name"
}

entrypoint_conforms() {
    local entry_name="$1" func probe_root out err funcfile probe_script fake_tool status ok probe_pid watchdog_pid
    func="$(entrypoint_main_name "$entry_name")"
    probe_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-wp41-probe.XXXXXX")"
    cp -R "$ROOT/bin" "$probe_root/bin"
    mkdir -p "$probe_root/fake-path" "$probe_root/home" "$probe_root/state"
    for fake_tool in container docker ssh; do
        printf '#!/bin/sh\nexit 1\n' > "$probe_root/fake-path/$fake_tool"
        chmod +x "$probe_root/fake-path/$fake_tool"
    done
    out="$probe_root/stdout"; err="$probe_root/stderr"; funcfile="$probe_root/func"
    : > "$out"; : > "$err"
    probe_script="$probe_root/probe.sh"
    cat > "$probe_script" <<'PROBE'
#!/bin/bash
set -euo pipefail
entry="$1"; func="$2"; funcfile="$3"
# shellcheck disable=SC1090
source "$entry"
if declare -F "$func" >/dev/null 2>&1; then
    printf defined > "$funcfile"
else
    printf missing > "$funcfile"
fi
PROBE
    (
        cd "$probe_root" || exit 90
        HOME="$probe_root/home" \
        XDG_STATE_HOME="$probe_root/state" \
        PATH="$probe_root/fake-path:/usr/bin:/bin" \
        bash "$probe_script" "$probe_root/bin/$entry_name" "$func" "$funcfile"
    ) </dev/null >"$out" 2>"$err" &
    probe_pid=$!
    ( sleep 20; kill -9 "$probe_pid" 2>/dev/null ) &
    watchdog_pid=$!
    status=0
    wait "$probe_pid" || status=$?
    kill "$watchdog_pid" 2>/dev/null
    wait "$watchdog_pid" 2>/dev/null
    ok=0
    if [ ! -s "$out" ] && [ ! -s "$err" ] && [ "$status" -eq 0 ] && [ "$(cat "$funcfile" 2>/dev/null)" = defined ]; then
        ok=1
    fi
    rm -rf "$probe_root"
    [ "$ok" -eq 1 ]
}

for entrypoint_path in "$ROOT"/bin/dx*; do
    entrypoint_name="$(basename "$entrypoint_path")"
    [ "$entrypoint_name" != dx-lib.sh ] || continue
    check entrypoint_conforms "$entrypoint_name"
done

# --- WP1.8 (Fable D6): a column-0 (not indented -- and, by every test
# file's own convention already used throughout this repository, therefore
# never inside a `( … )` subshell, function, or case body) definition of a
# coreutils or runtime-boundary command as a shell function shadows that
# command for every LATER line that runs in the same shell process --
# including code deep inside test_helpers.sh or a sourced production
# library -- for as long as it stays defined. test_refactor_state_machines.sh
# :305-311 shows the correct discipline this contract enforces: define, use
# for the case(s) that need it, then `unset -f` the name before anything
# else in the file can be shadowed by it.
LEAK_PATTERN='^(mv|cp|rm|stat|chown|chmod|install|ln|mkdir|find|date|sleep|kill|nix|docker|container|ssh|git|jq|tar|useradd|mount|umount|truncate|mkfs\.[a-z0-9]+|findmnt|blkid|setpriv|id)\(\)[[:space:]]*\{'

# Scans every test_*.sh directly under $1 (no recursion -- every suite in
# this repository lives flat under tests/) for LEAK_PATTERN matches at
# column 0, and reports each one with no LATER `unset -f` line naming it.
# awk reads the file itself rather than piping a captured "rest of the
# file" string through `grep -q`: `grep -q` exits at its first match and
# closes its read end, and under `set -o pipefail` (this file's own line 2)
# the resulting SIGPIPE on the upstream write can fail an otherwise-true
# "already unset" case -- the identical SIGPIPE-under-pipefail defect
# `bootstrap_invokes` below is already written to avoid, encountered again
# while developing this very detector.
scan_leaking_overrides() {
    local dir="$1" file name lineno defline matches=""
    for file in "$dir"/test_*.sh; do
        [ -f "$file" ] || continue
        while IFS=: read -r lineno defline; do
            name="$(printf '%s' "$defline" | sed -E 's/^([A-Za-z0-9_.]+)\(\).*/\1/')"
            if awk -v n="$lineno" -v target="$name" '
                NR > n && /^[[:space:]]*unset[[:space:]]+-f[[:space:]]/ {
                    line = $0
                    sub(/^[[:space:]]*unset[[:space:]]+-f[[:space:]]+/, "", line)
                    split(line, names, /[[:space:]]+/)
                    for (i in names) if (names[i] == target) found = 1
                }
                END { exit (found ? 0 : 1) }
            ' "$file"; then
                :
            else
                matches="$matches$file:$lineno: $name()"$'\n'
            fi
        done < <(grep -nE "$LEAK_PATTERN" "$file")
    done
    printf '%s' "$matches"
}
leak_detected() { [ -n "$(scan_leaking_overrides "$1")" ]; }

# Self-proof before the real scan is trusted (test_runtime_boundary_audit.sh's
# own red/green discipline): a real leak must be caught, a column-0
# override properly wrapped in a `( … )` subshell must not, and a column-0
# override followed later in the same file by its own `unset -f` must not.
leak_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-leak-contract.XXXXXX")"
mkdir -p "$leak_fixture/red" "$leak_fixture/green-subshell" "$leak_fixture/green-unset"
cat > "$leak_fixture/red/test_leak_example.sh" <<'EOF'
#!/bin/bash
mv() { :; }
echo done
EOF
cat > "$leak_fixture/green-subshell/test_leak_example.sh" <<'EOF'
#!/bin/bash
(
    mv() { :; }
    echo done
)
EOF
cat > "$leak_fixture/green-unset/test_leak_example.sh" <<'EOF'
#!/bin/bash
mv() { :; }
echo done
unset -f mv
EOF
check leak_detected "$leak_fixture/red"
check reject leak_detected "$leak_fixture/green-subshell"
check reject leak_detected "$leak_fixture/green-unset"
rm -rf "$leak_fixture"

# The real gate: no tests/test_*.sh may define a column-0 coreutils/
# boundary-command override that outlives the file without an `unset -f`.
real_leaks="$(scan_leaking_overrides "$ROOT/tests")"
if [ -n "$real_leaks" ]; then
    echo "FAIL: leaking column-0 override(s) found (WP1.8):" >&2
    printf '%s' "$real_leaks" >&2
    failures=$((failures + 1))
fi

# --- WP1.7 (Fable D10): a bare `sleep <number>` command line inside a
# unit-tier test file is exactly the timing-assumption smell D10 flags --
# real wall-clock time standing in for a synchronisation signal, invisible
# to a fixture faking DX_SLEEP, and liable to flake under host load or race
# ahead of it. The line-anchored shape below is deliberately narrow: it
# catches a standalone `sleep N` statement (optionally indented), the exact
# shape every evidenced hit in this repository actually takes, and lets a
# real wait spawned through another command on the same line (`bash -c
# 'sleep 1' &`, the disguise wait_for_pid_exit's own tests/test_harness.sh
# cases use so a real, killable background timer does not itself trip this
# contract) through untouched -- that is not the smell being hunted here,
# and D10's own evidence list contains no such shape.
#
# Most suites carry no `# tier:` header yet (WP1.4 adds them repo-wide), so
# this gate is scoped for now to the files that already have one, plus an
# explicit list of the container-free suites WP1.7 itself de-flaked down to
# zero bare sleeps. Every other file's remaining bare sleeps are reported by
# WP1.7's own accompanying notes for WP1.4 to fold in as it adds headers,
# not enforced here.
BARE_SLEEP_PATTERN='^[[:space:]]*sleep[[:space:]]+[0-9]'

scan_bare_sleep() {
    grep -nE "$BARE_SLEEP_PATTERN" "$1" 2>/dev/null || true
}
bare_sleep_detected() { [ -n "$(scan_bare_sleep "$1")" ]; }

# Self-proof on two fixtures (the WP1.8 leak contract's own shape, above):
# a real bare sleep must be caught, and the same wait disguised behind
# another command on the line -- a real, backgroundable wait, not a no-op --
# must not.
sleep_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-sleep-contract.XXXXXX")"
mkdir -p "$sleep_fixture/red" "$sleep_fixture/green"
cat > "$sleep_fixture/red/test_sleep_example.sh" <<'EOF'
#!/bin/bash
echo before
sleep 2
echo after
EOF
cat > "$sleep_fixture/green/test_sleep_example.sh" <<'EOF'
#!/bin/bash
echo before
bash -c 'sleep 2' &
pid=$!
wait "$pid"
echo after
EOF
check bare_sleep_detected "$sleep_fixture/red/test_sleep_example.sh"
check reject bare_sleep_detected "$sleep_fixture/green/test_sleep_example.sh"
rm -rf "$sleep_fixture"

# The files this gate actually enforces today: every tests/test_*.sh that
# carries `# tier: unit`, now that WP1.4 has added that header repo-wide,
# EXCEPT two documented exclusions:
#
#   - test_refactor_contracts.sh itself: its own WP1.7 self-proof above
#     writes a fixture file's literal `sleep 2` line into ITS OWN source
#     text (between the `cat > ... <<'EOF'` / `EOF` markers a few hundred
#     lines up) to prove scan_bare_sleep can catch a real one -- that text
#     is fixture data one indirection away from this file's own control
#     flow, not a real wall-clock wait in it, so scanning this file's own
#     source for the pattern it exists to detect is definitionally a false
#     positive. (Every OTHER fixture heredoc in this file already avoids
#     this by not embedding a bare `sleep N` inside itself.)
#   - the six suites WP1.4 newly tagged `# tier: unit` that still carry
#     real, pre-existing bare sleeps WP1.7 evidenced but did not reach:
#     test_section14_tinty_theming.sh, test_section16_persist_storage.sh,
#     test_section17_dx_ai_runtime.sh, test_section19_reverse_forward.sh,
#     test_section23_herdr.sh, test_section27_qnap_scripts.sh. WP1.4's own
#     mandate is a header-only change (nothing else in a suite's body may
#     move, so concurrent edits from other in-flight work keep merging
#     cleanly); de-flaking these six is real body-editing work for a
#     follow-up D10 pass, not silently dropped -- named here instead of
#     just quietly passing.
unit_tier_sleep_files="test_bootstrap_publication.sh"
unit_tier_sleep_debt="test_refactor_contracts.sh test_section14_tinty_theming.sh test_section16_persist_storage.sh test_section17_dx_ai_runtime.sh test_section19_reverse_forward.sh test_section23_herdr.sh test_section27_qnap_scripts.sh"
sleep_debt_excluded() { contains_word "$1" "$unit_tier_sleep_debt"; }
for candidate in "$ROOT"/tests/test_*.sh; do
    candidate_name="$(basename "$candidate")"
    if grep -q '^# tier: unit' "$candidate" 2>/dev/null && ! sleep_debt_excluded "$candidate_name"; then
        unit_tier_sleep_files="$unit_tier_sleep_files $candidate_name"
    fi
done

for enforced_name in $unit_tier_sleep_files; do
    enforced_file="$ROOT/tests/$enforced_name"
    [ -f "$enforced_file" ] || continue
    enforced_hits="$(scan_bare_sleep "$enforced_file")"
    if [ -n "$enforced_hits" ]; then
        echo "FAIL: bare \`sleep <number>\` in unit-tier file $enforced_name (Fable D10):" >&2
        printf '%s\n' "$enforced_hits" >&2
        failures=$((failures + 1))
    fi
done

# --- WP1.4 (Fable D2, corrects Muse D1 / Astra R2): registering one test
# used to touch up to seven places (KNOWN_SECTIONS, run_test in
# run_all_tests.sh, run-tier.sh's own hand list, run-bash32-tests.sh's file
# list, run-coverage-contracts.sh's file list, this file's B2 literal list,
# and the paragraph a new test forces into ratchet.env) and the local
# `unit/static` tier had already silently drifted from what CI actually
# runs (it omitted sections 0, 4, 19, 24 and 33 -- all container-free, all
# dispatched by run_all_tests.sh unconditionally). The fix: every
# tests/test_*.sh declares its own `# tier: unit|host-contract|live|
# destructive` and `# bash32: yes|no` header; tests/run.sh selects suites by
# reading them instead of any hand list. This contract is what makes that
# trustworthy -- a suite with no header, or two, would otherwise make
# tests/run.sh's sweep silently run one fewer (or an ambiguous) suite,
# exactly the "tier shrinks and CI still goes green" failure class B2 above
# already exists to catch for the OLD registry.
tier_header_count() { grep -c '^# tier: ' "$1" 2>/dev/null; }
bash32_header_count() { grep -c '^# bash32: ' "$1" 2>/dev/null; }

# suite_header_ok FILE -- true if FILE carries exactly one `# tier:` header
# with a recognised value, AND exactly one `# bash32:` header with a
# recognised value. Four separate checks (not one aggregate condition) so a
# violation is attributable: "no tier header" reads differently from "tier
# header present twice" or "tier header present once but spelled wrong".
suite_header_ok() {
    local file="$1"
    [ "$(tier_header_count "$file")" -eq 1 ] || return 1
    case "$(sed -n 's/^# tier: //p' "$file" | head -n1)" in
        unit|host-contract|live|destructive) ;;
        *) return 1 ;;
    esac
    [ "$(bash32_header_count "$file")" -eq 1 ] || return 1
    case "$(sed -n 's/^# bash32: //p' "$file" | head -n1)" in
        yes|no) ;;
        *) return 1 ;;
    esac
    return 0
}

# Self-proof before the real scan is trusted (this file's own established
# discipline: the WP1.8 leak scan and the WP1.7 bare-sleep scan both prove
# themselves on fixtures before the real gate below relies on them). Four
# fixtures: no header at all (red), a header repeated twice (red), a header
# present once but with an unrecognised value (red), and exactly one valid
# `# tier:` plus one valid `# bash32:` (green).
header_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-header-contract.XXXXXX")"
cat > "$header_fixture_dir/test_none.sh" <<'EOF'
#!/bin/bash
set -euo pipefail
echo hi
EOF
cat > "$header_fixture_dir/test_twice.sh" <<'EOF'
#!/bin/bash
# tier: unit
# tier: live
# bash32: yes
set -euo pipefail
EOF
cat > "$header_fixture_dir/test_bad_value.sh" <<'EOF'
#!/bin/bash
# tier: sometimes
# bash32: yes
set -euo pipefail
EOF
cat > "$header_fixture_dir/test_valid.sh" <<'EOF'
#!/bin/bash
# tier: unit
# bash32: no
set -euo pipefail
EOF
check reject suite_header_ok "$header_fixture_dir/test_none.sh"
check reject suite_header_ok "$header_fixture_dir/test_twice.sh"
check reject suite_header_ok "$header_fixture_dir/test_bad_value.sh"
check suite_header_ok "$header_fixture_dir/test_valid.sh"
rm -rf "$header_fixture_dir"

# The real gate: every tests/test_*.sh in this repository (the exact glob
# tests/run.sh sweeps for a --tier run) must pass the same check --
# EXCEPT this file itself: its own fixtures above (test_none.sh/test_twice.sh/
# test_bad_value.sh/test_valid.sh, and the manifest-consistency fixtures
# further down) write several literal `# tier: ...`/`# bash32: ...` lines
# into ITS OWN source text on purpose, to prove suite_header_ok can tell a
# missing/duplicate/invalid header from a valid one -- so a whole-file
# `grep -c` of this file's own text always finds more than one of each,
# regardless of what this file's REAL header (line 2-4, checked directly
# below) says. Scanning this file for the exact pattern it exists to detect
# is the same self-reference the WP1.7 bare-sleep exclusion above already
# documents.
header_failures=""
for header_target in "$ROOT"/tests/test_*.sh; do
    case "$(basename "$header_target")" in
        test_refactor_contracts.sh) continue ;;
    esac
    suite_header_ok "$header_target" || header_failures="$header_failures$header_target"$'\n'
done
if [ -n "$header_failures" ]; then
    echo "FAIL: missing/duplicate/unrecognised tier or bash32 header (WP1.4 / Fable D2):" >&2
    printf '%s' "$header_failures" >&2
    failures=$((failures + 1))
fi
# This file's own real header, checked directly by line position instead of
# the whole-file scan the exclusion above skips for it.
check test "$(sed -n '2p' "$ROOT/tests/test_refactor_contracts.sh")" = '# tier: unit'
check test "$(sed -n '3p' "$ROOT/tests/test_refactor_contracts.sh")" = '# bash32: yes'

# --- WP1.4 manifest consistency: every section run_all_tests.sh dispatches
# must carry a `# tier:` header consistent with WHERE it dispatches from. A
# run_test call nested inside "if [ "$SKIP_INTEGRATION" = false ]; then
# ... fi" only ever runs against a running guest (tier: live, today
# sections 11 and 12); every OTHER dispatched section already proves it
# does no live work under SKIP_INTEGRATION=true (that is what
# `run_all_tests.sh --skip-integration` running it unconditionally means,
# and tests/test_section20_skip_integration.sh polices exactly that
# property for three of them directly), so it must be tier: unit. Sections
# 9 and 18 are deliberately included in that "must be unit" set: run-tier.sh
# separately calls them "host-contract" today, but nothing about either
# suite needs a running guest (both already pass in CI's container-free
# "Container-free contracts" job, unconditionally) -- WP1.4 picks `unit` for
# them per Fable D2's own Green step and keeps run-tier.sh's `host-contract`
# case working by naming those two sections directly instead of by tier.
#
# expected_tier_for_dispatch RUNNER DISPATCH_LINENO -- 'live' if the line
# immediately above DISPATCH_LINENO in RUNNER opens the
# SKIP_INTEGRATION-false conditional, else 'unit'. Reused (not
# reimplemented) by tests/run.sh's own --section resolution below, so the
# two never see a different answer for the same file.
expected_tier_for_dispatch() {
    local runner="$1" dispatch_lineno="$2" prev_lineno prev_text
    prev_lineno=$((dispatch_lineno - 1))
    prev_text="$(sed -n "${prev_lineno}p" "$runner")"
    case "$prev_text" in
        *'if [ "$SKIP_INTEGRATION" = false ]; then'*) printf 'live\n' ;;
        *) printf 'unit\n' ;;
    esac
}

# Self-proof on a small fixture runner before trusting it against the real
# run_all_tests.sh: a dispatch line right after the conditional's `if`
# expects live, one outside it expects unit, and a file whose OWN header
# disagrees with that expectation must be reported.
manifest_fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-manifest-tier-contract.XXXXXX")"
mkdir -p "$manifest_fixture_dir/tests"
cat > "$manifest_fixture_dir/runner.sh" <<'EOF'
run_test "$SCRIPT_DIR/test_a.sh" "1"
if [ "$SKIP_INTEGRATION" = false ]; then
    run_test "$SCRIPT_DIR/test_b.sh" "2"
fi
EOF
cat > "$manifest_fixture_dir/tests/test_a.sh" <<'EOF'
# tier: unit
EOF
cat > "$manifest_fixture_dir/tests/test_b.sh" <<'EOF'
# tier: live
EOF
cat > "$manifest_fixture_dir/tests/test_b_wrong.sh" <<'EOF'
# tier: unit
EOF
manifest_tier_matches() {
    local runner="$1" dispatch_lineno="$2" tests_dir="$3" filename="$4"
    local expected actual
    expected="$(expected_tier_for_dispatch "$runner" "$dispatch_lineno")"
    actual="$(sed -n 's/^# tier: //p' "$tests_dir/$filename" | head -n1)"
    [ "$actual" = "$expected" ]
}
check manifest_tier_matches "$manifest_fixture_dir/runner.sh" 1 "$manifest_fixture_dir/tests" test_a.sh
check manifest_tier_matches "$manifest_fixture_dir/runner.sh" 3 "$manifest_fixture_dir/tests" test_b.sh
check reject manifest_tier_matches "$manifest_fixture_dir/runner.sh" 3 "$manifest_fixture_dir/tests" test_b_wrong.sh
rm -rf "$manifest_fixture_dir"

# The real gate: parse run_all_tests.sh's own dispatch table (the same
# run_test regex B2 above already uses) and check every dispatched file's
# real header against expected_tier_for_dispatch.
manifest_runner="$ROOT/tests/run_all_tests.sh"
while IFS=: read -r manifest_lineno manifest_dispatch_text; do
    manifest_file="$(printf '%s' "$manifest_dispatch_text" | sed -E 's/.*\$SCRIPT_DIR\/([^"]+)".*/\1/')"
    manifest_expected="$(expected_tier_for_dispatch "$manifest_runner" "$manifest_lineno")"
    manifest_actual="$(sed -n 's/^# tier: //p' "$ROOT/tests/$manifest_file" | head -n1)"
    check test "$manifest_actual" = "$manifest_expected"
done < <(grep -nE 'run_test[[:space:]]+"\$SCRIPT_DIR/[^"]+"[[:space:]]+"[0-9]+"' "$manifest_runner")

[ "$failures" -eq 0 ]
