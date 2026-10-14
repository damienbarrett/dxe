#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.3 (plans/do D-4, D-9; spec R5, R6, R19, R22): the `persist-dir` mount
# role and the guest environment bin/dx-create-container passes.
#
# Interface contract (pinned by this file; the implementation must match):
#   * New volume-spec role `persist-dir:PATH:TARGET:MODE` (MODE rw|ro).
#     dx_runtime_container_create_parse_volume_spec sets
#       DXE_VOLSPEC_ROLE=persist-dir  DXE_VOLSPEC_NAME=PATH
#       DXE_VOLSPEC_TARGET=TARGET     DXE_VOLSPEC_MODE=MODE
#     and returns 0. A persist-dir spec whose PATH contains ':' (so it does
#     not split into exactly four fields) or ',' (it would inject extra
#     --mount options) returns non-zero with a message that names
#     `persist-dir` and says the path must not contain ':' (resp. ',').
#   * The refusal happens in the parser, so it fires before any runtime call
#     in either adapter.
#   * Docker adapter renders the role as ONE argv pair
#       --mount type=bind,source=PATH,target=TARGET           (rw)
#       --mount type=bind,source=PATH,target=TARGET,readonly  (ro)
#     never `-v` / `--volume` for it, makes no `volume inspect` /
#     ownership call for it, and creates nothing on the NAS.
#   * Apple adapter refuses the role: non-zero, a message containing both
#     `persist-dir` and `docs/guest.md`, and no `container` call recorded.
#   * bin/dx-create-container, DX_PERSIST_STORAGE=host-path (docker-ssh):
#       - replaces the `--volume persist:...:/persist:rw` item with
#         `--volume persist-dir:$DX_PERSIST_HOST_ROOT/dxe/$DX_CONTAINER_NAME/persist:/persist:rw`
#         (rendered as the single --mount above), exactly one --mount in all;
#       - adds `--env DX_PERSIST_STORAGE=host-path` and
#         `--env DX_PERSIST_DIR_GUEST=$DX_CONTAINER_NAME`;
#       - changes nothing else in the create argv (nix and bootstrap volumes,
#         other env, publish, labels, entrypoint are as in volume mode);
#       - makes no call that mentions the (unused) persist volume name.
#   * DX_PERSIST_STORAGE=volume: the create argv is byte-identical to
#     tests/fixtures/persist-dir-volume-create-argv.txt, captured on the tree
#     before WP3.3. In particular neither DX_PERSIST_STORAGE nor
#     DX_PERSIST_DIR_GUEST is passed in volume mode (the guest treats an
#     unset DX_PERSIST_STORAGE as `volume`).
#   * Nothing here creates a directory on the NAS: no `mkdir` in any recorded
#     ssh or docker call.
#   * Fixture normalisation (done by this file's docker fake, so the fixture
#     is stable): an argv element containing a newline is recorded as
#     <MULTILINE-ARG>, `HOST_TZ=...` as HOST_TZ=<tz>, and the discovered
#     guest SSH address prefix as <ADDR>.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
# shellcheck source=lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"
source "$BASE_DIR/bin/lib/dx-container.sh"

test_section "WP3.3: persist-dir mount role and guest environment"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-dir-mount.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home"
VOLUME_FIXTURE="$SCRIPT_DIR/fixtures/persist-dir-volume-create-argv.txt"
# Assembled, never a literal dotted quad (tests/test_section1_secrets.sh).
ADDR="$(printf '%s.%s.%s.%s' 100 64 1 2)"

# --- shared fakes -----------------------------------------------------------

# Writes a fresh tool directory into $TOOLS with: a management-plane ssh that
# evals its command (fake_qnap_ssh_write), a tailscale answering the fixture
# address, a uname, and a recording docker. Logs (fresh per call):
#   $CALLS  every docker call, "$*" per line
#   $ARGV   normalised argv of the guest-container create, one element/line
#   $SSHLOG every ssh argv element, one per line
new_world() {
    local n="$1"
    TOOLS="$(fake_tool_dir_create "$fixture")"
    CALLS="$fixture/calls.$n"; ARGV="$fixture/argv.$n"; SSHLOG="$fixture/ssh.$n"
    : > "$CALLS"; : > "$ARGV"; : > "$SSHLOG"
    fake_qnap_ssh_write "$TOOLS"
    fake_tool_write "$TOOLS" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_tool_write "$TOOLS" tailscale "case \"\$*\" in
    \"ip -4\") printf '%s\\n' '$ADDR' ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac"
    fake_tool_write "$TOOLS" docker "
if [ \"\$1 \$2 \$3\" = \"create --name \$DX_CONTAINER_NAME\" ]; then
    printf 'create --name %s (argv in the argv log)\\n' \"\$3\" >> '$CALLS'
else
    printf '%s\\n' \"\$*\" >> '$CALLS'
fi
case \"\$1 \$2\" in
    'version --format') echo 27.3.1; exit 0 ;;
    'info --format') echo 'abc123def|qnap-fake|x86_64|linux'; exit 0 ;;
    'image inspect') echo sha256:cafe; exit 0 ;;
    'volume inspect') exit 1 ;;
    'container inspect')
        case \"\$*\" in
            *dxe-lock-*) echo \"true|dxe-fixture-nas.invalid__\$DX_CONTAINER_NAME|lock|\$DXE_LIFECYCLE_LOCK_OWNER\"; exit 0 ;;
            *) exit 1 ;;
        esac ;;
esac
if [ \"\$1\" = create ] && [ \"\$2\" = --name ] && [ \"\$3\" = \"\$DX_CONTAINER_NAME\" ]; then
    for a in \"\$@\"; do
        case \"\$a\" in
            *\$'\\n'*) a='<MULTILINE-ARG>' ;;
            HOST_TZ=*) a='HOST_TZ=<tz>' ;;
            '$ADDR':*) a=\"<ADDR>:\${a#*:}\" ;;
        esac
        printf '%s\\n' \"\$a\" >> '$ARGV'
    done
fi
exit 0"
    # Log every ssh argv element (one per line) before evaluating it.
    mv "$TOOLS/ssh" "$TOOLS/ssh.real"
    fake_tool_write "$TOOLS" ssh "printf '%s\\n' \"\$@\" >> '$SSHLOG'
exec '$TOOLS/ssh.real' \"\$@\""
}

# run_create N [VAR=VALUE ...]: runs the real bin/dx-create-container against
# the fakes; sets CC_RC and CC_OUT. Config is pinned explicitly so the argv
# does not depend on registry defaults.
run_create() {
    local n="$1"; shift
    new_world "$n"
    CC_OUT="$(env -i HOME="$fixture/home" PATH="$TOOLS:/usr/bin:/bin" \
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid \
        DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume \
        DX_CONTAINER_NAME=dx-fix DX_IMAGE=dx-fix-img \
        DX_NIX_VOLUME=dx-fix-nix DX_PERSIST_VOLUME=dx-fix-persist DX_BOOTSTRAP_VOLUME=dx-fix-bootstrap \
        DX_BOOTSTRAP_PATH=/guest-bootstrap DX_GUEST_ACTIVATION_TIMEOUT=1800 \
        DX_GUEST_ACTIVATION_ATTEMPTS=2 DX_GUEST_ACTIVATION_RETRY_DELAY=5 DX_NIX_DISK_SIZE=64G \
        DX_CONTAINER_MEMORY=12G DX_CONTAINER_CPUS=4 DX_SSH_PORT=2222 DX_CONTAINER_RESTART_POLICY=no \
        DX_GIT_MOUNT_SOURCE='' DX_SSH_KEY_PUB="$fixture/no-such-key.pub" \
        "$@" "$BASE_DIR/bin/dx-create-container" 2>&1)"
    CC_RC=$?
}

# Drops one "FLAG VALUE" pair (two adjacent lines) from a one-per-line argv.
drop_pair() { # file flag value-prefix
    awk -v f="$2" -v v="$3" '
        pending { pending = 0; if (index($0, v) == 1) next; print held; print; next }
        $0 == f { pending = 1; held = $0; next }
        { print }' "$1"
}
has_pair() { # file flag value  (exact adjacent lines)
    awk -v f="$2" -v v="$3" 'prev == f && $0 == v { found = 1 } { prev = $0 } END { exit !found }' "$1"
}
# Any mkdir in the recorded management-plane calls? The guest and lock
# `docker create` lines are excluded: their entrypoint script legitimately
# runs mkdir inside the guest.
host_mkdir_calls() { # calls-log ssh-log
    local f
    for f in "$1" "$2"; do
        grep -Fv -e ' create --name ' -e 'create --name ' "$f" | grep -F mkdir | cut -c1-200
    done
}
count_line() { grep -Fxc -- "$2" "$1" || true; }

# --- 1. parser --------------------------------------------------------------

parse_case() { # spec -> "rc|ROLE|NAME|TARGET|MODE|message"
    (
        DXE_VOLSPEC_ROLE=""; DXE_VOLSPEC_NAME=""; DXE_VOLSPEC_TARGET=""; DXE_VOLSPEC_MODE=""
        msg="$(dx_runtime_container_create_parse_volume_spec "$1" 2>&1)"; rc=$?
        # The function runs in the command substitution's subshell; call it
        # again in this shell for its exported results.
        dx_runtime_container_create_parse_volume_spec "$1" >/dev/null 2>&1
        printf '%s|%s|%s|%s|%s|%s' "$rc" "$DXE_VOLSPEC_ROLE" "$DXE_VOLSPEC_NAME" "$DXE_VOLSPEC_TARGET" "$DXE_VOLSPEC_MODE" "$msg"
    )
}

got="$(parse_case 'persist-dir:/share/dxe/g/persist:/persist:rw')"
[ "$got" = '0|persist-dir|/share/dxe/g/persist|/persist|rw|' ] \
    && test_pass "parse: persist-dir:PATH:TARGET:rw sets role, name=PATH, target, mode" \
    || test_fail "parse: persist-dir:PATH:TARGET:rw sets role, name=PATH, target, mode (got: $got)"
got="$(parse_case 'persist-dir:/share/dxe/g/persist:/persist:ro')"
[ "$got" = '0|persist-dir|/share/dxe/g/persist|/persist|ro|' ] \
    && test_pass "parse: persist-dir with mode ro" \
    || test_fail "parse: persist-dir with mode ro (got: $got)"
got="$(parse_case 'persist:vol:/persist:rw')"
[ "$got" = '0|persist|vol|/persist|rw|' ] \
    && test_pass "parse: the persist role is unchanged" \
    || test_fail "parse: the persist role is unchanged (got: $got)"

got="$(parse_case 'persist-dir:/share/a:b/persist:/persist:rw')"
rc="${got%%|*}"
if [ "$rc" != 0 ] && grep -Fq 'persist-dir' <<<"$got" && grep -Fq "must not contain ':'" <<<"$got"; then
    test_pass "parse: a persist-dir path containing ':' is refused with a message naming persist-dir"
else test_fail "parse: a persist-dir path containing ':' is refused with a message naming persist-dir (got: $got)"; fi
got="$(parse_case 'persist-dir:/share/a,readonly=false/persist:/persist:rw')"
rc="${got%%|*}"
if [ "$rc" != 0 ] && grep -Fq 'persist-dir' <<<"$got" && grep -Fq "must not contain ','" <<<"$got"; then
    test_pass "parse: a persist-dir path containing ',' (mount-option injection) is refused"
else test_fail "parse: a persist-dir path containing ',' (mount-option injection) is refused (got: $got)"; fi

# --- 2. Docker adapter rendering -------------------------------------------

# adapter_create N RUNTIME SPEC...: dx_runtime_container_create with the given
# --volume specs under the fakes; sets AD_RC, AD_OUT; ARGV/CALLS/SSHLOG as in
# new_world (the guest name there is dx-fix).
adapter_create() {
    local n="$1" runtime="$2"; shift 2
    local vols=() spec
    for spec in "$@"; do vols+=(--volume "$spec"); done
    new_world "$n"
    AD_OUT="$(
        PATH="$TOOLS:/usr/bin:/bin"
        DX_RUNTIME="$runtime" DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_CONTAINER_NAME=dx-fix DX_GUEST_SYSTEM=x86_64-linux
        export DX_CONTAINER_NAME DX_GUEST_SYSTEM DXE_RUNTIME_DOCKER_BIN=docker
        unset DXE_RUNTIME_GUEST_SSH_ADDRESS
        dx_runtime_container_create --name dx-fix --image dx-fix-img \
            --volume nix:dx-fix-nix:rw ${vols[@]+"${vols[@]}"} \
            --memory 12G --cpus 4 --publish 2222:2222 --restart-policy no \
            --entrypoint-cmd 'echo hi' --entrypoint-arg /guest-bootstrap 2>&1
    )"
    AD_RC=$?
}

adapter_create 1 docker-ssh 'persist-dir:/fixture-root/dxe/dx-fix/persist:/persist:rw' 'bootstrap:dx-fix-bootstrap:/guest-bootstrap:rw'
if [ "$AD_RC" -eq 0 ] && has_pair "$ARGV" --mount 'type=bind,source=/fixture-root/dxe/dx-fix/persist,target=/persist' \
    && [ "$(count_line "$ARGV" --mount)" -eq 1 ]; then
    test_pass "docker: persist-dir rw renders exactly one --mount type=bind,source=PATH,target=TARGET"
else test_fail "docker: persist-dir rw renders exactly one --mount type=bind,source=PATH,target=TARGET (rc=$AD_RC)"; cat "$ARGV"; echo "$AD_OUT"; fi
if [ -s "$ARGV" ] && [ "$(count_line "$ARGV" -v)" -eq 0 ] && ! grep -Fq ':/persist:' "$ARGV" \
    && ! grep -Fq -- '/fixture-root' <(awk 'prev == "--volume" { print } { prev = $0 }' "$ARGV"); then
    test_pass "docker: persist-dir is never rendered with -v or --volume"
else test_fail "docker: persist-dir is never rendered with -v or --volume"; cat "$ARGV"; fi
if [ -s "$ARGV" ] && has_pair "$ARGV" --volume dx-fix-nix:/nix:rw && has_pair "$ARGV" --volume dx-fix-bootstrap:/guest-bootstrap:rw; then
    test_pass "docker: the other volumes still render as --volume NAME:TARGET:MODE beside a persist-dir"
else test_fail "docker: the other volumes still render as --volume NAME:TARGET:MODE beside a persist-dir"; cat "$ARGV"; fi
if ! grep -Fq 'volume' <(grep -F '/fixture-root' "$CALLS"); then
    test_pass "docker: no volume or ownership call is made for a persist-dir path"
else test_fail "docker: no volume or ownership call is made for a persist-dir path"; cat "$CALLS"; fi
if [ -s "$ARGV" ] && [ -z "$(host_mkdir_calls "$CALLS" "$SSHLOG")" ]; then
    test_pass "docker: rendering a persist-dir creates nothing on the host (no mkdir)"
else test_fail "docker: rendering a persist-dir creates nothing on the host (no mkdir)"; host_mkdir_calls "$CALLS" "$SSHLOG"; fi

adapter_create 2 docker-ssh 'persist-dir:/fixture-root/dxe/dx-fix/persist:/persist:ro'
if [ "$AD_RC" -eq 0 ] && has_pair "$ARGV" --mount 'type=bind,source=/fixture-root/dxe/dx-fix/persist,target=/persist,readonly'; then
    test_pass "docker: persist-dir ro appends ,readonly"
else test_fail "docker: persist-dir ro appends ,readonly (rc=$AD_RC)"; cat "$ARGV"; fi

adapter_create 3 docker-ssh 'persist-dir:/fixture root/dxe/dx-fix/persist:/persist:rw'
if [ "$AD_RC" -eq 0 ] && has_pair "$ARGV" --mount 'type=bind,source=/fixture root/dxe/dx-fix/persist,target=/persist'; then
    test_pass "docker: a persist-dir path with a space reaches docker as one argv element"
else test_fail "docker: a persist-dir path with a space reaches docker as one argv element (rc=$AD_RC)"; cat "$ARGV"; echo "$AD_OUT"; fi

# --- 3. colon / comma refusal before any runtime call ----------------------

for bad in 'persist-dir:/fixture-root/a:b/persist:/persist:rw' 'persist-dir:/fixture-root/a,b/persist:/persist:rw'; do
    adapter_create 4 docker-ssh "$bad"
    if [ "$AD_RC" -ne 0 ] && grep -Fq 'persist-dir' <<<"$AD_OUT" && [ ! -s "$CALLS" ] && [ ! -s "$SSHLOG" ] && [ ! -s "$ARGV" ]; then
        test_pass "docker: '$bad' is refused before any ssh or docker call"
    else test_fail "docker: '$bad' is refused before any ssh or docker call (rc=$AD_RC)"; echo "$AD_OUT"; cat "$CALLS" "$SSHLOG"; fi
done

# --- 4. Apple refusal -------------------------------------------------------

with_fake_runtime container
: > "$FAKE_TRANSCRIPT"
ap_out="$(DX_RUNTIME=apple dx_runtime_container_create --name dx-fix --image dx-fix-img \
    --volume nix:dx-fix-nix:rw --volume 'persist-dir:/fixture-root/dxe/dx-fix/persist:/persist:rw' \
    --memory 12G --cpus 4 --publish 2222:2222 --entrypoint-cmd 'echo hi' --entrypoint-arg /guest-bootstrap 2>&1)"
ap_rc=$?
if [ "$ap_rc" -ne 0 ] && grep -Fq 'persist-dir' <<<"$ap_out" && grep -Fq 'docs/guest.md' <<<"$ap_out"; then
    test_pass "apple: a persist-dir spec exits non-zero with a message pointing at docs/guest.md"
else test_fail "apple: a persist-dir spec exits non-zero with a message pointing at docs/guest.md (rc=$ap_rc)"; echo "$ap_out"; fi
if [ ! -s "$FAKE_TRANSCRIPT" ]; then
    test_pass "apple: the persist-dir refusal records no container call"
else test_fail "apple: the persist-dir refusal records no container call"; cat "$FAKE_TRANSCRIPT"; fi

# --- 5. dx-create-container, host-path mode --------------------------------

HOST_ROOT=/fixture-root
run_create 5 DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT="$HOST_ROOT"
host_argv="$fixture/host-argv"; cp "$ARGV" "$host_argv"; host_calls="$CALLS"; host_ssh="$SSHLOG"
if [ "$CC_RC" -eq 0 ] && has_pair "$host_argv" --mount "type=bind,source=$HOST_ROOT/dxe/dx-fix/persist,target=/persist" \
    && [ "$(count_line "$host_argv" --mount)" -eq 1 ]; then
    test_pass "host-path: dx-create-container records exactly one --mount type=bind,source=<root>/dxe/<guest>/persist,target=/persist"
else test_fail "host-path: dx-create-container records exactly one --mount for the derived source (rc=$CC_RC)"; echo "$CC_OUT" | tail -n 5; cat "$host_argv"; fi
if [ -s "$host_argv" ] && [ "$(count_line "$host_argv" -v)" -eq 0 ] \
    && ! grep -Eq ':/persist(:|$)' "$host_argv"; then
    test_pass "host-path: no -v or --volume carries /persist"
else test_fail "host-path: no -v or --volume carries /persist"; cat "$host_argv"; fi
if has_pair "$host_argv" -e DX_PERSIST_STORAGE=host-path && has_pair "$host_argv" -e DX_PERSIST_DIR_GUEST=dx-fix; then
    test_pass "host-path: DX_PERSIST_STORAGE=host-path and DX_PERSIST_DIR_GUEST=<guest> are passed as environment"
else test_fail "host-path: DX_PERSIST_STORAGE=host-path and DX_PERSIST_DIR_GUEST=<guest> are passed as environment"; cat "$host_argv"; fi
if [ -s "$host_calls" ] && ! grep -Fq 'dx-fix-persist' "$host_calls"; then
    test_pass "host-path: no call mentions the unused persist volume"
else test_fail "host-path: no call mentions the unused persist volume"; cat "$host_calls"; fi
if [ -s "$host_argv" ] && [ -s "$host_ssh" ] && [ -z "$(host_mkdir_calls "$host_calls" "$host_ssh")" ]; then
    test_pass "host-path: dx-create-container creates no directory on the host (no mkdir)"
else test_fail "host-path: dx-create-container creates no directory on the host (no mkdir)"; host_mkdir_calls "$host_calls" "$host_ssh"; fi

# --- 6. dx-create-container, volume mode -----------------------------------

run_create 6 DX_PERSIST_STORAGE=volume
vol_argv="$fixture/vol-argv"; cp "$ARGV" "$vol_argv"
if [ "$CC_RC" -eq 0 ] && [ -s "$vol_argv" ] && [ -f "$VOLUME_FIXTURE" ] && cmp -s "$VOLUME_FIXTURE" "$vol_argv"; then
    test_pass "volume mode: the create argv is byte-identical to the pre-WP3.3 fixture (R6)"
else test_fail "volume mode: the create argv is byte-identical to the pre-WP3.3 fixture (R6) (rc=$CC_RC)"; diff "$VOLUME_FIXTURE" "$vol_argv" | head -n 20; fi
if has_pair "$vol_argv" --volume dx-fix-persist:/persist:rw; then
    test_pass "volume mode: /persist is still the named volume"
else test_fail "volume mode: /persist is still the named volume"; cat "$vol_argv"; fi
if [ -s "$vol_argv" ] && ! grep -Fq 'DX_PERSIST_STORAGE' "$vol_argv" && ! grep -Fq 'DX_PERSIST_DIR_GUEST' "$vol_argv" \
    && [ "$(count_line "$vol_argv" --mount)" -eq 0 ]; then
    test_pass "volume mode: neither guest variable is passed and there is no --mount"
else test_fail "volume mode: neither guest variable is passed and there is no --mount"; cat "$vol_argv"; fi

# Unset DX_PERSIST_STORAGE is volume mode: same bytes.
run_create 7
if [ "$CC_RC" -eq 0 ] && [ -s "$ARGV" ] && cmp -s "$VOLUME_FIXTURE" "$ARGV"; then
    test_pass "volume mode: an unset DX_PERSIST_STORAGE yields the same fixture bytes"
else test_fail "volume mode: an unset DX_PERSIST_STORAGE yields the same fixture bytes (rc=$CC_RC)"; fi

# Host-path argv differs from volume argv only by the persist item and the two variables.
host_rest="$fixture/host-rest"; vol_rest="$fixture/vol-rest"
drop_pair "$host_argv" --mount 'type=bind,source=' | drop_pair /dev/stdin -e DX_PERSIST_STORAGE= | drop_pair /dev/stdin -e DX_PERSIST_DIR_GUEST= > "$host_rest"
drop_pair "$vol_argv" --volume 'dx-fix-persist:/persist' > "$vol_rest"
if [ -s "$host_rest" ] && cmp -s "$host_rest" "$vol_rest"; then
    test_pass "host-path differs from volume mode only by the --mount item and the two guest variables"
else test_fail "host-path differs from volume mode only by the --mount item and the two guest variables"; diff "$vol_rest" "$host_rest" | head -n 20; fi

# --- 7. Apple + host-path (R22) --------------------------------------------

with_fake_runtime container
: > "$FAKE_TRANSCRIPT"
ap2_out="$(env -i HOME="$fixture/home" PATH="$PATH" DX_RUNTIME=apple DX_CONTAINER_NAME=dx-fix DX_IMAGE=dx-fix-img \
    DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/fixture-root "$BASE_DIR/bin/dx-create-container" 2>&1)"
ap2_rc=$?
if [ "$ap2_rc" -ne 0 ] && grep -Fq 'docs/guest.md' <<<"$ap2_out" && [ ! -s "$FAKE_TRANSCRIPT" ]; then
    test_pass "apple: dx-create-container with DX_PERSIST_STORAGE=host-path is refused, pointing at docs/guest.md, no container call"
else test_fail "apple: dx-create-container with DX_PERSIST_STORAGE=host-path is refused, pointing at docs/guest.md, no container call (rc=$ap2_rc)"; echo "$ap2_out" | tail -n 4; cat "$FAKE_TRANSCRIPT"; fi

print_summary
exit_with_code
