#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP7.1: everything about the LIVE /persist host-path suite
# (tests/test_persist_host_dir_live.sh) that can be proven without a NAS:
#   - persist_live_guard (tests/lib/persist-live.sh) refuses every profile the
#     live suite must never run on, one `Refusing:` line per broken rule, and
#     makes no command call at all;
#   - the share confinement: persist_live_share_path_ok accepts only
#     <root>/dxe/<canary>, and persist_live_root_sh starts exactly one root
#     one-off container (pinned argv) binding only that directory, or none;
#   - the in-container scripts, run here under sh and dash against a
#     temporary canary directory: they move, replace and restore the leaf and
#     the marker exactly as the live cases need, refuse shapes they did not
#     make, and touch nothing outside the canary directory;
#   - tests/profiles/qnap-persist-canary-example.env validates through
#     bin/dx-profile and passes the guard;
#   - the live suite's own gates: it skips without --live or without the
#     opt-in, refuses a non-canary profile, and with a canary profile and a
#     failing management connection stops at the read-only preflight -- in
#     every case before any write reaches the (fake, fail-closed) NAS.
# The in-container scripts run real mv, rm, rmdir, chmod and ln, but only
# inside a temporary directory this suite creates (checked before each run).
# No test here reaches a real host: every network tool is a fail-closed fake.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/persist-live.sh
source "$SCRIPT_DIR/lib/persist-live.sh"

test_section "WP7.1: live-suite guard, share confinement and in-container scripts (no NAS)"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-live-guard.XXXXXX")" || exit 1
case "$SCRATCH" in
    */dxe-persist-live-guard.??????) : ;;
    *) echo "unexpected scratch path: $SCRATCH" >&2; exit 1 ;;
esac
trap 'rm -rf "$SCRATCH"' EXIT
mkdir -p "$SCRATCH/tmp" "$SCRATCH/home" "$SCRATCH/profiles"

has() { grep -Fq -- "$2" <<<"$1"; }
count_refusals() { grep -c '^Refusing: ' <<<"$1" || true; }

# --- persist_live_guard ---------------------------------------------------------
# shellcheck disable=SC2034 # read by persist_live_guard and the helpers it is passed to
canary_env() {
    DXE_PERSIST_LIVE_CANARY=dx-live-canary
    DX_CONTAINER_NAME=dx-live-canary
    DX_RUNTIME=docker-ssh
    DX_REMOTE_HOST=dxe-fixture-nas.invalid
    DX_PERSIST_STORAGE=host-path
    DX_PERSIST_HOST_ROOT=/fixture/share
    DX_NIX_VOLUME=dx-live-canary-nix
    DX_PERSIST_VOLUME=dx-live-canary-persist
    DX_BOOTSTRAP_VOLUME=dx-live-canary-bootstrap
    DX_IMAGE=dx-live-canary-image
    DX_SSH_KEY=/fixture/keys/dx-live-canary_key
    DX_SSH_KEY_PUB=/fixture/keys/dx-live-canary_key.pub
    DX_SSH_PORT=2224
    DX_CONTAINER_RESTART_POLICY=no
    DX_USAGE_SERVICE=off
    DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-fixture-sentinel
}

# guard_run [NAME=VALUE | -NAME]... -- the guard's stderr, then rc=<status>,
# over canary_env with the given changes (-NAME unsets NAME). PATH holds no
# executable at all, so any command the guard tried to run would fail.
guard_run() {
    (
        canary_env
        for change in "$@"; do
            case "$change" in
                -*) unset "${change#-}" ;;
                *) printf -v "${change%%=*}" '%s' "${change#*=}" ;;
            esac
        done
        # shellcheck disable=SC2123 # deliberately no command search path at all
        PATH="$SCRATCH/no-commands"
        { persist_live_guard >/dev/null; } 2>&1
        echo "rc=$?"
    )
}

out="$(guard_run)"
if [ "$out" = "rc=0" ]; then
    test_pass "the guard accepts a complete canary profile silently, with no command on PATH"
else test_fail "the guard accepts a complete canary profile silently, with no command on PATH (got: $out)"; fi

# expect_one_refusal DESCRIPTION MESSAGE CHANGE...
expect_one_refusal() {
    local description="$1" message="$2" result
    shift 2
    result="$(guard_run "$@")"
    if has "$result" "rc=1" && has "$result" "Refusing: $message" && [ "$(count_refusals "$result")" = 1 ]; then
        test_pass "guard refuses $description with one line"
    else
        test_fail "guard refuses $description with one line (got: $result)"
    fi
}

expect_one_refusal "a missing opt-in" "DXE_PERSIST_LIVE_CANARY must equal DX_CONTAINER_NAME (dx-live-canary)" -DXE_PERSIST_LIVE_CANARY
expect_one_refusal "an opt-in naming another canary" "DXE_PERSIST_LIVE_CANARY must equal DX_CONTAINER_NAME (dx-live-canary)" DXE_PERSIST_LIVE_CANARY=dx-other-canary
expect_one_refusal "DX_RUNTIME=apple" "DX_RUNTIME must be docker-ssh (got 'apple')." DX_RUNTIME=apple
expect_one_refusal "volume storage" "DX_PERSIST_STORAGE must be host-path (got 'volume')." DX_PERSIST_STORAGE=volume
expect_one_refusal "a non-canary nix volume" 'DX_NIX_VOLUME=dx-qnap-nix does not contain "canary"' DX_NIX_VOLUME=dx-qnap-nix
expect_one_refusal "a non-canary persist volume" 'DX_PERSIST_VOLUME=dx-qnap-persist does not contain "canary"' DX_PERSIST_VOLUME=dx-qnap-persist
expect_one_refusal "a non-canary bootstrap volume" 'DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap does not contain "canary"' DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap
expect_one_refusal "an empty persist volume name" 'DX_PERSIST_VOLUME= does not contain "canary"' DX_PERSIST_VOLUME=
expect_one_refusal "a non-canary image" 'DX_IMAGE=dx-qnap-nixos does not contain "canary"; dx-destroy and dx-factory-reset delete the image by name.' DX_IMAGE=dx-qnap-nixos
expect_one_refusal "the production key pair" "DX_SSH_KEY=/fixture/keys/qnap is not a canary key" DX_SSH_KEY=/fixture/keys/qnap
expect_one_refusal "a key that is canary only by its directory" "DX_SSH_KEY_PUB=/fixture/canary/dx_key.pub is not a canary key" DX_SSH_KEY_PUB=/fixture/canary/dx_key.pub
expect_one_refusal "the default SSH port" "DX_SSH_PORT=2222 is the default guest port" DX_SSH_PORT=2222
expect_one_refusal "the usage service's host port" "DX_SSH_PORT=8787 is the usage service's default host port" DX_SSH_PORT=8787
expect_one_refusal "an unless-stopped restart policy" "DX_CONTAINER_RESTART_POLICY must be no (got 'unless-stopped')" DX_CONTAINER_RESTART_POLICY=unless-stopped
expect_one_refusal "the usage service" "DX_USAGE_SERVICE must be off (got 'on')" DX_USAGE_SERVICE=on
expect_one_refusal "an empty mount sentinel" "DX_PERSIST_HOST_MOUNT_SENTINEL is empty" DX_PERSIST_HOST_MOUNT_SENTINEL=

for root in "" / relative/share /share//x /share/./x /share/../x /share/x/ /share/x/. /share/x/..; do
    expect_one_refusal "the share root '$root'" "DX_PERSIST_HOST_ROOT must be a normalised absolute path other than / (got '$root')." "DX_PERSIST_HOST_ROOT=$root"
done

for name in dx-qnap-persist qnap-canary dx-Canary dx-canary_1 dx-canary.x "dx-canary x" dx-; do
    expect_one_refusal "the container name '$name'" "DX_CONTAINER_NAME=$name is not a canary name" "DX_CONTAINER_NAME=$name" "DXE_PERSIST_LIVE_CANARY=$name"
done

for protected in dx-host dx-test dx-qnap; do
    result="$(guard_run "DX_CONTAINER_NAME=$protected" "DXE_PERSIST_LIVE_CANARY=$protected")"
    if has "$result" "rc=1" && has "$result" "Refusing: DX_CONTAINER_NAME=$protected is a protected guest" \
        && has "$result" "Refusing: DX_CONTAINER_NAME=$protected is not a canary name" && [ "$(count_refusals "$result")" = 2 ]; then
        test_pass "guard refuses the protected guest $protected (protected and not a canary name)"
    else test_fail "guard refuses the protected guest $protected (got: $result)"; fi
done

for name in dx-canary dx-qnap-persist-canary dx-canary-2 dx-0canary9; do
    result="$(guard_run "DX_CONTAINER_NAME=$name" "DXE_PERSIST_LIVE_CANARY=$name")"
    if [ "$result" = "rc=0" ]; then
        test_pass "guard accepts the canary name $name"
    else test_fail "guard accepts the canary name $name (got: $result)"; fi
done

result="$(guard_run DXE_PERSIST_LIVE_CANARY=dx-qnap DX_CONTAINER_NAME=dx-qnap DX_NIX_VOLUME=dx-qnap-nix \
    DX_PERSIST_VOLUME=dx-qnap-persist DX_BOOTSTRAP_VOLUME=dx-qnap-bootstrap DX_IMAGE=dx-qnap-nixos \
    DX_SSH_KEY=/fixture/keys/qnap DX_SSH_KEY_PUB=/fixture/keys/qnap.pub DX_SSH_PORT=2222 \
    DX_CONTAINER_RESTART_POLICY=unless-stopped DX_USAGE_SERVICE=on DX_PERSIST_STORAGE=volume)"
if has "$result" "rc=1" && [ "$(count_refusals "$result")" = 12 ]; then
    test_pass "a production-shaped profile is refused on every rule it breaks (12 lines)"
else test_fail "a production-shaped profile is refused on every rule it breaks (got $(count_refusals "$result"): $result)"; fi

# --- derived paths, marker text, kv -----------------------------------------
(
    canary_env
    [ "$(persist_live_canary_dir)" = /fixture/share/dxe/dx-live-canary ] \
        && [ "$(persist_live_leaf)" = /fixture/share/dxe/dx-live-canary/persist ]
) && test_pass "the canary directory and leaf are <root>/dxe/<name> and <root>/dxe/<name>/persist" \
  || test_fail "the canary directory and leaf are <root>/dxe/<name> and <root>/dxe/<name>/persist"
(
    canary_env
    # shellcheck disable=SC2034 # read by persist_live_record_path
    XDG_STATE_HOME=/fixture/state
    [ "$(persist_live_record_path)" = /fixture/state/dxe/persist-dirs/dxe-fixture-nas.invalid__dx-live-canary ] || exit 1
    unset XDG_STATE_HOME
    HOME=/fixture/home
    [ "$(persist_live_record_path)" = /fixture/home/.local/state/dxe/persist-dirs/dxe-fixture-nas.invalid__dx-live-canary ]
) && test_pass "the D-7 record path is <XDG_STATE_HOME or ~/.local/state>/dxe/persist-dirs/<remote>__<name>" \
  || test_fail "the D-7 record path is <XDG_STATE_HOME or ~/.local/state>/dxe/persist-dirs/<remote>__<name>"
expected_marker="$(printf 'schema=1\nguest=dx-live-canary\nstate=retired\nsource-volume=dx-live-canary-persist\ncreated-at=2026-10-11T01:02:03Z\nretired-at=2026-10-12T04:05:06Z')"
if [ "$(persist_live_marker_text dx-live-canary retired dx-live-canary-persist 2026-10-11T01:02:03Z "" 2026-10-12T04:05:06Z)" = "$expected_marker" ] \
    && [ "$(persist_live_marker_text g ready)" = "$(printf 'schema=1\nguest=g\nstate=ready')" ]; then
    test_pass "persist_live_marker_text writes plan D-3's lines, optional keys only when given"
else test_fail "persist_live_marker_text writes plan D-3's lines, optional keys only when given"; fi
kv_text="$(printf 'root=/a\nstate=empty\nstate=other\ncreated-at=x=y')"
if [ "$(persist_live_kv state "$kv_text")" = empty ] && [ "$(persist_live_kv created-at "$kv_text")" = x=y ] \
    && [ -z "$(persist_live_kv missing "$kv_text")" ]; then
    test_pass "persist_live_kv returns the first KEY= value, or nothing"
else test_fail "persist_live_kv returns the first KEY= value, or nothing"; fi

# --- share confinement --------------------------------------------------------
share_ok() {
    (
        canary_env
        [ "$#" -lt 2 ] || printf -v "${2%%=*}" '%s' "${2#*=}"
        persist_live_share_path_ok "$1"
    )
}
if share_ok /fixture/share/dxe/dx-live-canary; then
    test_pass "the canary's own directory is the one share path the suite may bind"
else test_fail "the canary's own directory is the one share path the suite may bind"; fi
for path in "" / /fixture/share /fixture/share/dxe /fixture/share/dxe/dx-qnap /fixture/share/dxe/dx-live-canary/ \
    /fixture/share/dxe/dx-live-canary/persist /fixture/share/dxe/dx-live-canary/.. /fixture/share/dxe/dx-other-canary; do
    if share_ok "$path"; then
        test_fail "the share path '$path' is refused"
    else test_pass "the share path '$path' is refused"; fi
done
if share_ok /fixture/../dxe/dx-live-canary DX_PERSIST_HOST_ROOT=/fixture/..; then
    test_fail "a non-normalised root is refused even for its own canary directory"
else test_pass "a non-normalised root is refused even for its own canary directory"; fi
if share_ok /fixture/share/dxe/dx-qnap DX_CONTAINER_NAME=dx-qnap; then
    test_fail "a non-canary guest's directory is refused even when it is the configured one"
else test_pass "a non-canary guest's directory is refused even when it is the configured one"; fi

# root_sh_record MODE [NAME=VALUE] -- runs persist_live_root_sh with a recording
# dxe_runtime_call (argv one per line, then the bytes it read on stdin).
root_sh_record() {
    local mode="$1" rc
    rm -f "$SCRATCH/argv" "$SCRATCH/stdin"
    (
        canary_env
        [ "$#" -lt 2 ] || printf -v "${2%%=*}" '%s' "${2#*=}"
        dxe_runtime_call() { printf '%s\n' "$@" >"$SCRATCH/argv"; cat >"$SCRATCH/stdin"; }
        printf 'marker-bytes\n' | persist_live_root_sh "$mode" 'echo the script' one two 2>"$SCRATCH/root-sh.err"
    )
    rc=$?
    echo "rc=$rc"
}
expected_argv="$(printf '%s\n' dx_runtime_run_ephemeral --rm -i --network none --user 0:0 --pull never \
    --label dxe.role=persist-live --mount type=bind,source=/fixture/share/dxe/dx-live-canary,target=/canary \
    --entrypoint sh dx-live-canary-image -c 'echo the script' sh /canary one two)"
out="$(root_sh_record rw)"
if [ "$out" = rc=0 ] && [ "$(cat "$SCRATCH/argv")" = "$expected_argv" ] && [ "$(cat "$SCRATCH/stdin")" = marker-bytes ]; then
    test_pass "persist_live_root_sh rw: one root one-off container, exact argv, bind of the canary directory only, stdin passed"
else test_fail "persist_live_root_sh rw: one root one-off container, exact argv (got $out: $(tr '\n' ' ' <"$SCRATCH/argv" 2>/dev/null))"; fi
out="$(root_sh_record ro)"
if [ "$out" = rc=0 ] && [ "$(cat "$SCRATCH/argv")" = "${expected_argv/target=\/canary/target=/canary,readonly}" ]; then
    test_pass "persist_live_root_sh ro: the same container with a readonly bind"
else test_fail "persist_live_root_sh ro: the same container with a readonly bind (got $out: $(tr '\n' ' ' <"$SCRATCH/argv" 2>/dev/null))"; fi
for refusal in "rx" "rw DX_PERSIST_HOST_ROOT=/fixture/../etc" "rw DX_CONTAINER_NAME=dx-qnap" "rw DX_PERSIST_HOST_ROOT=/"; do
    # shellcheck disable=SC2086 # the mode and the one change are two words on purpose
    out="$(root_sh_record $refusal)"
    if [ "$out" = rc=2 ] && [ ! -e "$SCRATCH/argv" ] && grep -q '^Refusing: persist_live_root_sh' "$SCRATCH/root-sh.err"; then
        test_pass "persist_live_root_sh refuses ($refusal) with no container started"
    else test_fail "persist_live_root_sh refuses ($refusal) with no container started (got $out)"; fi
done

# --- the in-container scripts -------------------------------------------------
for name in ASIDE REPLACE RESTORE_LEAF MARKER_OUT MARKER_RESTORE LEAF_MODE RETIRE STAT; do
    var="PERSIST_LIVE_SCRIPT_$name"
    script="${!var}"
    case "$script" in
        *"
"* | *"'"*) test_fail "$var is one line with no single quote (the NAS transport %q-quotes argv)" ;;
        'unset CDPATH; cd -P -- "$1" || '*) test_pass "$var is one line with no single quote and starts in the canary directory" ;;
        *) test_fail "$var starts with the canary-directory prelude" ;;
    esac
done

MARKER_READY="$(persist_live_marker_text dx-live-canary ready "" 2026-10-11T01:02:03Z)"
MARKER_OTHER="$(persist_live_marker_text dx-live-other-canary ready "" 2026-10-11T01:02:03Z)"
CASE_N=0
CANARY=""

# new_canary -- a fresh case directory: canary/persist (marker, dxe-live, home)
# and a sibling outside/ the scripts must never touch. Sets CANARY (not run in
# a command substitution, so CASE_N advances).
new_canary() {
    local base
    CASE_N=$((CASE_N + 1))
    base="$SCRATCH/case-$CASE_N"
    mkdir -p "$base/canary/persist/dxe-live" "$base/canary/persist/home" "$base/outside"
    printf '%s\n' "$MARKER_READY" >"$base/canary/persist/.dxe-persist-dir"
    printf 'token-%s\n' "$CASE_N" >"$base/canary/persist/dxe-live/app-state.txt"
    printf 'keep\n' >"$base/outside/keep.txt"
    chmod 0755 "$base/canary/persist"
    chmod 0644 "$base/canary/persist/.dxe-persist-dir"
    CANARY="$base/canary"
}

# The bare image the live containers run has no sed and no awk. Every script runs
# here with a PATH holding only symlinks to the tools that image has, so a script
# that calls anything else fails the case instead of failing on the NAS.
BARE_TOOLS="$SCRATCH/bare-tools"
mkdir -p "$BARE_TOOLS"
for tool in ls grep stat mktemp find du df sort head cksum cat mv rm mkdir chmod ln rmdir printf echo test; do
    tool_path="$(command -v "$tool" 2>/dev/null)"
    case "$tool_path" in /*) ln -s "$tool_path" "$BARE_TOOLS/$tool" ;; *) : ;; esac
done
for tool in sed awk; do
    if [ -e "$BARE_TOOLS/$tool" ]; then echo "bare tool dir must not hold $tool" >&2; exit 1; fi
done

# run_script SHELL CANARY SCRIPT [ARG...] (stdin passed): status of the script.
run_script() {
    local shell="$1" canary="$2" script="$3"
    shift 3
    case "$canary" in
        "$SCRATCH"/case-*/canary) : ;;
        *) echo "refusing to run a script outside the scratch area: $canary" >&2; return 99 ;;
    esac
    shell="$(command -v "$shell")"
    PATH="$BARE_TOOLS" "$shell" -c "$script" sh "$canary" "$@"
}

facts() { run_script "$1" "$2" "$PERSIST_LIVE_SCRIPT_STAT" </dev/null 2>/dev/null; }
owner_of() { ls -ldn "$1" | awk '{ print $3 ":" $4 }'; }
outside_ok() { [ "$(cat "${1%/canary}/outside/keep.txt")" = keep ] && [ "$(ls -A "${1%/canary}/outside")" = keep.txt ]; }

shells="sh"
if command -v dash >/dev/null 2>&1; then shells="sh dash"; fi
for sh_name in $shells; do
    new_canary
    canary="$CANARY"
    token="token-$CASE_N"
    owner="$(owner_of "$canary/persist")"
    base_facts="$(printf '%s\n' "leaf=dir" "leaf_owner=$owner" "leaf_mode=755" "marker=file" \
        "marker_owner=$(owner_of "$canary/persist/.dxe-persist-dir")" "marker_mode=644" \
        "entry=.dxe-persist-dir" "entry=dxe-live" "entry=home" "aside=absent" "orig=absent" "app_state=$token")"
    if [ "$(facts "$sh_name" "$canary")" = "$base_facts" ]; then
        test_pass "[$sh_name] STAT reports kind, owner, mode, entries, marker, aside slots and application state"
    else test_fail "[$sh_name] STAT reports the canary directory's facts (got: $(facts "$sh_name" "$canary" | tr '\n' ' '))"; fi

    for replacement in symlink empty unmarked; do
        run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_ASIDE" </dev/null
        aside_rc=$?
        run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_REPLACE" "$replacement" </dev/null
        replace_rc=$?
        now="$(facts "$sh_name" "$canary")"
        case "$replacement" in
            symlink) shape_ok=false; [ -L "$canary/persist" ] && [ "$(readlink "$canary/persist")" = persist.dxe-live-aside ] && shape_ok=true ;;
            empty) shape_ok=false; [ -d "$canary/persist" ] && [ -z "$(ls -A "$canary/persist")" ] && shape_ok=true ;;
            *) shape_ok=false; [ "$(ls -A "$canary/persist")" = dxe-live-unmarked ] && shape_ok=true ;;
        esac
        if [ "$aside_rc" = 0 ] && [ "$replace_rc" = 0 ] && $shape_ok && has "$now" "aside=dir"; then
            test_pass "[$sh_name] ASIDE then REPLACE $replacement puts that shape in the leaf's place"
        else test_fail "[$sh_name] ASIDE then REPLACE $replacement (rc $aside_rc/$replace_rc; $(printf '%s' "$now" | tr '\n' ' '))"; fi
        run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null
        restore_rc=$?
        if [ "$restore_rc" = 0 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ] && outside_ok "$canary"; then
            test_pass "[$sh_name] RESTORE_LEAF puts the real leaf back over a $replacement, nothing else touched"
        else test_fail "[$sh_name] RESTORE_LEAF puts the real leaf back over a $replacement (rc $restore_rc)"; fi
    done

    # The fresh-start shape: an empty stand-in that establish then marked.
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_ASIDE" </dev/null
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_REPLACE" empty </dev/null
    printf '%s\n' "$MARKER_READY" >"$canary/persist/.dxe-persist-dir"
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null
    restore_rc=$?
    if [ "$restore_rc" = 0 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ]; then
        test_pass "[$sh_name] RESTORE_LEAF removes a marked fresh-start stand-in and puts the real leaf back"
    else test_fail "[$sh_name] RESTORE_LEAF removes a marked fresh-start stand-in (rc $restore_rc)"; fi

    # A stand-in holding something the suite did not make is left alone.
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_ASIDE" </dev/null
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_REPLACE" empty </dev/null
    printf 'user data\n' >"$canary/persist/user-file"
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null 2>/dev/null
    restore_rc=$?
    if [ "$restore_rc" != 0 ] && [ "$(cat "$canary/persist/user-file")" = "user data" ] && [ -d "$canary/persist.dxe-live-aside/dxe-live" ]; then
        test_pass "[$sh_name] RESTORE_LEAF refuses a stand-in with entries it did not make and changes nothing"
    else test_fail "[$sh_name] RESTORE_LEAF refuses a stand-in with entries it did not make (rc $restore_rc)"; fi
    rm -f "$canary/persist/user-file"
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null

    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null
    restore_rc=$?
    if [ "$restore_rc" = 0 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ]; then
        test_pass "[$sh_name] RESTORE_LEAF with nothing aside does nothing"
    else test_fail "[$sh_name] RESTORE_LEAF with nothing aside does nothing (rc $restore_rc)"; fi

    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_REPLACE" empty </dev/null 2>/dev/null
    replace_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_ASIDE" </dev/null
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_ASIDE" </dev/null 2>/dev/null
    second_aside_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_REPLACE" bogus </dev/null 2>/dev/null
    bogus_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RESTORE_LEAF" </dev/null
    if [ "$replace_rc" != 0 ] && [ "$second_aside_rc" != 0 ] && [ "$bogus_rc" = 2 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ]; then
        test_pass "[$sh_name] REPLACE needs the leaf aside, ASIDE needs a real leaf, an unknown shape is refused"
    else test_fail "[$sh_name] REPLACE/ASIDE refusals (rc $replace_rc/$second_aside_rc/$bogus_rc)"; fi

    # Marker: hide, swap, restore.
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_OUT" hide </dev/null
    hide_rc=$?
    now="$(facts "$sh_name" "$canary")"
    if [ "$hide_rc" = 0 ] && has "$now" "marker=absent" && has "$now" "orig=file" \
        && [ "$(cat "$canary/marker.dxe-live-orig")" = "$MARKER_READY" ]; then
        test_pass "[$sh_name] MARKER_OUT hide moves the real marker out of the leaf, bytes kept"
    else test_fail "[$sh_name] MARKER_OUT hide (rc $hide_rc; $(printf '%s' "$now" | tr '\n' ' '))"; fi
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" </dev/null
    if [ "$?" = 0 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ] && [ "$(cat "$canary/persist/.dxe-persist-dir")" = "$MARKER_READY" ]; then
        test_pass "[$sh_name] MARKER_RESTORE puts the hidden marker back, byte for byte"
    else test_fail "[$sh_name] MARKER_RESTORE puts the hidden marker back"; fi
    printf '%s\n' "$MARKER_OTHER" | run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_OUT" swap
    swap_rc=$?
    now="$(facts "$sh_name" "$canary")"
    if [ "$swap_rc" = 0 ] && [ "$(cat "$canary/persist/.dxe-persist-dir")" = "$MARKER_OTHER" ] && has "$now" "marker_mode=644" \
        && [ "$(printf '%s\n' "$now" | grep -c '^entry=')" = 3 ] && [ "$(cat "$canary/marker.dxe-live-orig")" = "$MARKER_READY" ]; then
        test_pass "[$sh_name] MARKER_OUT swap writes stdin as a 0644 marker by temp file and mv, no temp left, original saved"
    else test_fail "[$sh_name] MARKER_OUT swap (rc $swap_rc; $(printf '%s' "$now" | tr '\n' ' '))"; fi
    printf 'x\n' | run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_OUT" swap 2>/dev/null
    second_swap_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_OUT" bogus </dev/null 2>/dev/null
    bogus_rc=$?
    if [ "$second_swap_rc" != 0 ] && [ "$bogus_rc" = 2 ] && [ "$(cat "$canary/persist/.dxe-persist-dir")" = "$MARKER_OTHER" ] \
        && [ "$(cat "$canary/marker.dxe-live-orig")" = "$MARKER_READY" ]; then
        test_pass "[$sh_name] MARKER_OUT never overwrites a saved original, and refuses an unknown action"
    else test_fail "[$sh_name] MARKER_OUT refusals (rc $second_swap_rc/$bogus_rc)"; fi
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" </dev/null
    restore_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_MARKER_RESTORE" </dev/null
    again_rc=$?
    if [ "$restore_rc" = 0 ] && [ "$again_rc" = 0 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ] \
        && [ "$(cat "$canary/persist/.dxe-persist-dir")" = "$MARKER_READY" ]; then
        test_pass "[$sh_name] MARKER_RESTORE replaces the swapped marker with the original, and is a no-op after that"
    else test_fail "[$sh_name] MARKER_RESTORE over a swapped marker (rc $restore_rc/$again_rc)"; fi

    # Leaf mode.
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0751 </dev/null
    mode_751="$(facts "$sh_name" "$canary" | sed -n 's/^leaf_mode=//p')"
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0777 </dev/null 2>/dev/null
    bad_mode_rc=$?
    mode_after_bad="$(facts "$sh_name" "$canary" | sed -n 's/^leaf_mode=//p')"
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_LEAF_MODE" 0755 </dev/null
    if [ "$mode_751" = 751 ] && [ "$bad_mode_rc" = 2 ] && [ "$mode_after_bad" = 751 ] && [ "$(facts "$sh_name" "$canary")" = "$base_facts" ]; then
        test_pass "[$sh_name] LEAF_MODE sets 0751 and 0755 only"
    else test_fail "[$sh_name] LEAF_MODE sets 0751 and 0755 only ($mode_751/$bad_mode_rc/$mode_after_bad)"; fi

    # Retire.
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RETIRE" "x/y" </dev/null 2>/dev/null
    bad_stamp_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RETIRE" 20261012T010203Z </dev/null
    retire_rc=$?
    run_script "$sh_name" "$canary" "$PERSIST_LIVE_SCRIPT_RETIRE" 20261012T010204Z </dev/null
    again_rc=$?
    if [ "$bad_stamp_rc" = 2 ] && [ "$retire_rc" = 0 ] && [ "$again_rc" = 0 ] && [ ! -e "$canary/persist" ] \
        && [ "$(cat "$canary/persist.dxe-live-removed-20261012T010203Z/dxe-live/app-state.txt")" = "$token" ] \
        && [ ! -e "$canary/persist.dxe-live-removed-20261012T010204Z" ] && outside_ok "$canary"; then
        test_pass "[$sh_name] RETIRE moves the leaf aside under a stamped name, deletes nothing, and is a no-op without a leaf"
    else test_fail "[$sh_name] RETIRE ($bad_stamp_rc/$retire_rc/$again_rc)"; fi
    if [ "$(ls -A "$canary" | tr '\n' ' ')" = "persist.dxe-live-removed-20261012T010203Z " ]; then
        test_pass "[$sh_name] after every script the canary directory holds only the suite's own names"
    else test_fail "[$sh_name] after every script the canary directory holds only the suite's own names (got: $(ls -A "$canary" | tr '\n' ' '))"; fi
done

# --- the library is import-only -------------------------------------------------
purity_probe="$SCRATCH/purity-probe.sh"
cat >"$purity_probe" <<'PROBE'
#!/bin/bash
before="$-|$(trap -p)|$(umask)|$PWD"
# shellcheck source=/dev/null
source "$1" >"$2" 2>&1
status=$?
after="$-|$(trap -p)|$(umask)|$PWD"
[ "$before" = "$after" ] || echo "state changed: $before -> $after" >>"$2"
exit "$status"
PROBE
if bash "$purity_probe" "$SCRIPT_DIR/lib/persist-live.sh" "$SCRATCH/purity.out" && [ ! -s "$SCRATCH/purity.out" ]; then
    test_pass "tests/lib/persist-live.sh is import-only: no output, no shell-state change"
else test_fail "tests/lib/persist-live.sh is import-only (got: $(cat "$SCRATCH/purity.out"))"; fi

# --- the tracked example profile -------------------------------------------------
example_env="$(env -i HOME="$SCRATCH/home" PATH="/usr/bin:/bin" DX_PROFILES_DIR="$BASE_DIR/tests/profiles" \
    "$BASE_DIR/bin/dx-profile" qnap-persist-canary-example /usr/bin/env 2>&1; echo "rc=$?")"
example_ok=true
for line in rc=0 DX_RUNTIME=docker-ssh DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/absolute/path/to/qnap-share \
    DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-share-mounted DX_CONTAINER_NAME=dx-qnap-persist-canary DX_CONTAINER_RESTART_POLICY=no \
    DX_USAGE_SERVICE=off DX_NIX_STORAGE_MODE=direct-volume; do
    grep -Fqx -- "$line" <<<"$example_env" || { example_ok=false; echo "  missing: $line"; }
done
if $example_ok; then
    test_pass "tests/profiles/qnap-persist-canary-example.env validates through dx-profile as a host-path docker-ssh canary"
else test_fail "tests/profiles/qnap-persist-canary-example.env validates through dx-profile ($(tail -n 3 <<<"$example_env"))"; fi
guard_probe="$SCRATCH/guard-probe.sh"
cat >"$guard_probe" <<'PROBE'
#!/bin/bash
set -u
# shellcheck source=/dev/null
source "$1"
persist_live_guard
PROBE
example_guard="$(env -i HOME="$SCRATCH/home" PATH="/usr/bin:/bin" DX_PROFILES_DIR="$BASE_DIR/tests/profiles" \
    DXE_PERSIST_LIVE_CANARY=dx-qnap-persist-canary \
    "$BASE_DIR/bin/dx-profile" qnap-persist-canary-example bash "$guard_probe" "$SCRIPT_DIR/lib/persist-live.sh" 2>&1; echo "rc=$?")"
if [ "$example_guard" = rc=0 ]; then
    test_pass "the live suite's guard accepts the example profile as it stands"
else test_fail "the live suite's guard accepts the example profile as it stands (got: $example_guard)"; fi

# --- the live suite's gates (fail-closed fakes for every network tool) ------
fakes="$(fake_tool_dir_create "$SCRATCH")" || exit 1
transcript="$SCRATCH/remote-transcript"
for tool in ssh scp sftp docker container tailscale curl nix ssh-keyscan; do
    fake_tool_write "$fakes" "$tool" 'printf "%s|" "${0##*/}" >>"$DXE_LIVE_GUARD_TRANSCRIPT"
for a in "$@"; do printf "%s " "$a" | tr "\n" " " >>"$DXE_LIVE_GUARD_TRANSCRIPT"; done
printf "\n" >>"$DXE_LIVE_GUARD_TRANSCRIPT"
echo "fake: no network in this suite" >&2
exit 255'
done
write_profile() {
    local name="$1" container="$2" port="$3" storage="${4:-host-path}"
    cat >"$SCRATCH/profiles/$name.env" <<EOF
export DX_RUNTIME=docker-ssh
export DX_REMOTE_HOST=dxe-fixture-nas.invalid
export DX_NIX_STORAGE_MODE=direct-volume
export DX_CONTAINER_RESTART_POLICY=no
export DX_CONTAINER_NAME=$container
export DX_IMAGE=$container-image
export DX_NIX_VOLUME=$container-nix
export DX_PERSIST_VOLUME=$container-persist
export DX_BOOTSTRAP_VOLUME=$container-bootstrap
export DX_SSH_KEY=$SCRATCH/home/.ssh/dxe/${container}_key
export DX_SSH_KEY_PUB=$SCRATCH/home/.ssh/dxe/${container}_key.pub
export DX_SSH_PORT=$port
export DX_PERSIST_STORAGE=$storage
export DX_PERSIST_HOST_ROOT=/fixture/share
export DX_PERSIST_HOST_MOUNT_SENTINEL=dxe-fixture-sentinel
EOF
}
write_profile live-canary dx-live-canary 2224
write_profile live-production dx-qnap 2223 volume

# run_live PROFILE SKIP_INTEGRATION OPT_IN [RUN_DIR] -- the live suite's output, then rc=N.
run_live() {
    : >"$transcript"
    env -i HOME="$SCRATCH/home" PATH="$fakes:/usr/bin:/bin" TMPDIR="$SCRATCH/tmp" \
        DX_PROFILES_DIR="$SCRATCH/profiles" SKIP_INTEGRATION="$2" DXE_PERSIST_LIVE_CANARY="$3" \
        DXE_PERSIST_LIVE_RUN_DIR="${4:-$SCRATCH/run-$1}" DXE_LIVE_GUARD_TRANSCRIPT="$transcript" \
        DXE_PERSIST_LIVE_KEEP_RUNNING="${LIVE_KEEP_RUNNING:-}" \
        "$BASE_DIR/bin/dx-profile" "$1" bash "$BASE_DIR/tests/test_persist_host_dir_live.sh" 2>&1
    echo "rc=$?"
}
no_remote_call() { [ ! -s "$transcript" ]; }

out="$(run_live live-canary true dx-live-canary)"
if has "$out" "rc=0" && has "$out" "Live /persist host-path suite skipped (SKIP_INTEGRATION is not false)" && no_remote_call; then
    test_pass "without --live the live suite skips (exit 0) and contacts nothing"
else test_fail "without --live the live suite skips (exit 0) and contacts nothing ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false "")"
if has "$out" "rc=0" && has "$out" "not opted in: set DXE_PERSIST_LIVE_CANARY" && no_remote_call; then
    test_pass "with --live but no DXE_PERSIST_LIVE_CANARY the live suite skips (exit 0) and contacts nothing"
else test_fail "with --live but no DXE_PERSIST_LIVE_CANARY the live suite skips ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-production false dx-qnap)"
if ! has "$out" "rc=0" && has "$out" "Refusing: DX_CONTAINER_NAME=dx-qnap is a protected guest" \
    && has "$out" "Refusing: DX_PERSIST_STORAGE must be host-path (got 'volume')." \
    && has "$out" "refuses this profile (the Refusing: lines above); nothing was contacted" && no_remote_call; then
    test_pass "opted in on a production-named volume-mode profile, the live suite refuses (non-zero) before any remote call"
else test_fail "the live suite refuses a production-named profile before any remote call ($(tail -n 6 <<<"$out"))"; fi

out="$(run_live live-canary false dx-other-canary)"
if ! has "$out" "rc=0" && has "$out" "Refusing: DXE_PERSIST_LIVE_CANARY must equal DX_CONTAINER_NAME (dx-live-canary)" && no_remote_call; then
    test_pass "an opt-in naming another guest is refused before any remote call"
else test_fail "an opt-in naming another guest is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false dx-live-canary "$BASE_DIR/tests")"
if ! has "$out" "rc=0" && has "$out" "is inside the checkout" && no_remote_call; then
    test_pass "a run directory inside the checkout is refused before any remote call"
else test_fail "a run directory inside the checkout is refused before any remote call ($(tail -n 4 <<<"$out"))"; fi

out="$(run_live live-canary false dx-live-canary)"
remote_lines="$(grep -c . "$transcript" || true)"
discovery_lines="$(grep -c '^ssh|.*NOTFOUND' "$transcript" || true)"
if ! has "$out" "rc=0" && has "$out" "Stopped at the first failure: preflight" \
    && has "$out" "DXE_PERSIST_LIVE_CLEANUP_ONLY=1 DXE_PERSIST_LIVE_RUN_DIR=$(cd "$SCRATCH/run-live-canary" && pwd -P) DXE_PERSIST_LIVE_CANARY=dx-live-canary ./bin/dx-profile live-canary tests/run.sh --live" \
    && [ "$remote_lines" -ge 1 ] && [ "$remote_lines" = "$discovery_lines" ]; then
    test_pass "a canary profile with a failing NAS connection stops at the preflight; its only remote attempt is the read-only Docker CLI discovery"
else test_fail "a canary profile with a failing NAS connection stops at the preflight ($remote_lines remote lines, $discovery_lines discovery; $(tail -n 6 <<<"$out"))"; fi
if [ -d "$SCRATCH/run-live-canary/logs" ] && [ -d "$SCRATCH/run-live-canary/state" ] && [ ! -e "$SCRATCH/home/.local/state/dxe" ]; then
    test_pass "the live suite keeps its state (XDG_STATE_HOME) in its run directory, never the operator's"
else test_fail "the live suite keeps its state (XDG_STATE_HOME) in its run directory, never the operator's"; fi
if has "$out" "Stopped the canary container" || has "$out" "DXE_PERSIST_LIVE_KEEP_RUNNING=1"; then
    test_fail "after a failure with no running container (the NAS is unreachable) the suite reports no stop"
else test_pass "after a failure with no running container (the NAS is unreachable) the suite reports no stop"; fi
failure_remote_lines="$remote_lines"
LIVE_KEEP_RUNNING=1
out="$(run_live live-canary false dx-live-canary)"
LIVE_KEEP_RUNNING=""
remote_lines="$(grep -c . "$transcript" || true)"
discovery_lines="$(grep -c '^ssh|.*NOTFOUND' "$transcript" || true)"
if ! has "$out" "rc=0" && has "$out" "DXE_PERSIST_LIVE_KEEP_RUNNING=1: the canary container is left as it is." \
    && [ "$remote_lines" -ge 1 ] && [ "$remote_lines" = "$discovery_lines" ] \
    && [ "$((remote_lines + 1))" = "$failure_remote_lines" ]; then
    test_pass "DXE_PERSIST_LIVE_KEEP_RUNNING=1 skips the after-failure stop: one remote query fewer (no running check, no stop)"
else test_fail "DXE_PERSIST_LIVE_KEEP_RUNNING=1 skips the after-failure stop ($remote_lines remote lines vs $failure_remote_lines without it, $discovery_lines discovery; $(tail -n 6 <<<"$out"))"; fi

print_summary
exit_with_code
