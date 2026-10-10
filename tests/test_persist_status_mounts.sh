#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP3.4 (plans/do D-6; spec R21, R35): actual /persist mounts, the dx-status
# "/persist storage" section, and the dx-start-container mismatch warning.
#
# Interface contract (pinned by this file; the implementation must match):
#   * dx_runtime_container_mounts NAME, declared in bin/lib/dx-runtime.sh and
#     dispatched (dx_runtime_dispatch container_mounts) to
#     dx_runtime_docker_container_mounts / dx_runtime_apple_container_mounts.
#     It prints one line per mount, `type|source|destination|rw`:
#       type         `volume` for a named volume, `bind` for a host
#                    directory bind (any other runtime type name is passed
#                    through unchanged);
#       source       for a named volume the VOLUME NAME (e.g. dx-persist),
#                    never the runtime's internal path; for a bind the
#                    absolute source path;
#       destination  the path inside the container;
#       rw           `rw` or `ro`.
#     Lines come in the runtime's order. A container that does not exist
#     (inspect fails) gives a non-zero status and NO stdout. Output has no
#     CR characters and no blank lines.
#   * Docker adapter: exactly one remote call through the existing transport
#     (ssh -> docker), with this argv (one element per line):
#       container
#       inspect
#       --format
#       {{range .Mounts}}{{.Type}}|{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}|{{if .RW}}rw{{else}}ro{{end}}{{println}}{{end}}
#       NAME
#     The adapter strips CR and drops blank lines from the reply.
#   * Apple adapter: `container inspect NAME` (JSON array) parsed WITHOUT jq
#     (the fake environment has no jq on PATH). Each element of
#     configuration.mounts looks like
#       {"type":{"volume":{"name":"N",...}},"source":"S","destination":"D","options":[...]}
#     for a volume (reported as volume|N|D|rw) and
#       {"type":{"virtiofs":{}},"source":"S","destination":"D","options":[...]}
#     for a host bind (reported as bind|S|D|rw). `ro` appears when
#     "options" contains "ro". Both compact (one-line) and pretty-printed
#     JSON must work.
#   * bin/dx-status prints a section headed `--- /persist storage ---`
#     (stopped or running container alike) containing the lines
#       configured: <volume name | derived host directory>
#       actual: <source of the mount whose destination is /persist>
#     Configured is $DX_PERSIST_VOLUME in volume mode and
#     $DX_PERSIST_HOST_ROOT/dxe/$DX_CONTAINER_NAME/persist in host-path
#     mode. With no container: `actual: (container not present)`. When
#     configured != actual the section also contains a line with the word
#     `mismatch` (and none otherwise); it never says the switch was
#     switched/migrated/completed/done. dx-status calls
#     dx_runtime_container_mounts with the container name.
#   * bin/dx-start-container, on a container whose actual /persist source
#     differs from the configured one, prints exactly ONE line (stdout or
#     stderr) containing `dx-recreate`: it starts with `Warning:` and
#     contains the container name, `/persist`, the configured source and the
#     actual source. It then carries on (exit 0, the container is started
#     when it was stopped, the bootstrap sync still runs). When they match,
#     no line mentions `dx-recreate`.
#   * Nothing here ever reaches a real runtime: fakes only.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$BASE_DIR/bin/lib/dx-config.sh"
source "$BASE_DIR/bin/lib/dx-host-util.sh"
source "$BASE_DIR/bin/lib/dx-runtime.sh"

test_section "WP3.4: actual /persist mounts, dx-status section, start warning"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-status.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/home"

DOCKER_FORMAT='{{range .Mounts}}{{.Type}}|{{if eq .Type "volume"}}{{.Name}}{{else}}{{.Source}}{{end}}|{{.Destination}}|{{if .RW}}rw{{else}}ro{{end}}{{println}}{{end}}'

# --- 1. Docker adapter -------------------------------------------------------

TOOLS="$(fake_tool_dir_create "$fixture")"
DLOG="$fixture/docker.log"; SLOG="$fixture/ssh.log"
: > "$DLOG"; : > "$SLOG"
fake_qnap_ssh_write "$TOOLS"
fake_tool_write "$TOOLS" docker "printf '%s\\n' \"\$@\" >> '$DLOG'; echo -- >> '$DLOG'
name=''; for a in \"\$@\"; do name=\"\$a\"; done
case \"\$name\" in
    dx-vol) printf 'volume|dx-persist|/persist|rw\\r\\nbind|/share/ws|/workspace|ro\\r\\n\\r\\n'; exit 0 ;;
    dx-hp) printf 'bind|/fixture-root/dxe/dx-hp/persist|/persist|rw\\n'; exit 0 ;;
    *) echo 'Error: No such container' >&2; exit 1 ;;
esac"

docker_mounts() { # name -> sets M_OUT, M_RC (docker-ssh runtime, fakes only)
    : > "$DLOG"; : > "$SLOG"
    M_OUT="$(PATH="$TOOLS:/usr/bin:/bin" HOME="$fixture/home" DX_RUNTIME=docker-ssh \
        DX_REMOTE_HOST=dxe-fixture-nas.invalid DXE_RUNTIME_DOCKER_BIN=docker \
        DXE_FAKE_SSH_ARGV_LOG="$SLOG" dx_runtime_container_mounts "$1" 2>/dev/null)"
    M_RC=$?
}

if ! type dx_runtime_container_mounts >/dev/null 2>&1; then
    test_fail "dx_runtime_container_mounts is declared in bin/lib/dx-runtime.sh"
else
    docker_mounts dx-vol
    want="$(printf 'volume|dx-persist|/persist|rw\nbind|/share/ws|/workspace|ro')"
    if [ "$M_RC" -eq 0 ] && [ "$M_OUT" = "$want" ]; then
        test_pass "docker: named volume and bind are normalised (CR and blank lines stripped, volume source = name)"
    else test_fail "docker: named volume and bind are normalised (rc=$M_RC got: $M_OUT)"; fi
    want_argv="$(printf 'container\ninspect\n--format\n%s\ndx-vol\n--' "$DOCKER_FORMAT")"
    if [ "$(cat "$DLOG")" = "$want_argv" ]; then
        test_pass "docker: exactly one docker call with the pinned container inspect --format argv"
    else test_fail "docker: exactly one docker call with the pinned argv (got: $(cat "$DLOG"))"; fi
    if [ -s "$SLOG" ] && grep -Fq dxe-fixture-nas.invalid "$SLOG"; then
        test_pass "docker: the call went through the ssh transport to the configured host"
    else test_fail "docker: the call went through the ssh transport to the configured host"; fi

    docker_mounts dx-hp
    if [ "$M_RC" -eq 0 ] && [ "$M_OUT" = 'bind|/fixture-root/dxe/dx-hp/persist|/persist|rw' ]; then
        test_pass "docker: a host-directory bind reports its absolute source"
    else test_fail "docker: a host-directory bind reports its absolute source (rc=$M_RC got: $M_OUT)"; fi

    docker_mounts dx-gone
    if [ "$M_RC" -ne 0 ] && [ -z "$M_OUT" ]; then
        test_pass "docker: a missing container is non-zero with no output"
    else test_fail "docker: a missing container is non-zero with no output (rc=$M_RC got: $M_OUT)"; fi
fi

# --- 2. Apple adapter --------------------------------------------------------

ATOOLS="$(fake_tool_dir_create "$fixture")"
ALOG="$fixture/container.log"; : > "$ALOG"
APPLE_VOL_COMPACT='[{"status":"running","configuration":{"id":"dx-vol","mounts":[{"type":{"virtiofs":{}},"source":"/Users/fix/ws","destination":"/workspace","options":["ro"]},{"type":{"volume":{"name":"dx-persist","source":"/vol/dx-persist/volume.img","format":"ext4"}},"source":"/vol/dx-persist/volume.img","destination":"/persist","options":[]}]}}]'
fake_tool_write "$ATOOLS" container "printf '%s\\n' \"\$*\" >> '$ALOG'
case \"\$*\" in
    'inspect dx-vol') cat '$fixture/apple-vol.json'; exit 0 ;;
    'inspect dx-pretty') cat '$fixture/apple-pretty.json'; exit 0 ;;
    'inspect dx-hp') cat '$fixture/apple-hp.json'; exit 0 ;;
    *) echo 'Error: not found' >&2; exit 1 ;;
esac"
printf '%s\n' "$APPLE_VOL_COMPACT" > "$fixture/apple-vol.json"
cat > "$fixture/apple-pretty.json" <<'JSON'
[
  {
    "status": "stopped",
    "configuration": {
      "id": "dx-pretty",
      "mounts": [
        {
          "type": { "volume": { "name": "dx-persist", "source": "/vol/dx-persist/volume.img", "format": "ext4" } },
          "source": "/vol/dx-persist/volume.img",
          "destination": "/persist",
          "options": []
        }
      ]
    }
  }
]
JSON
printf '%s\n' '[{"configuration":{"id":"dx-hp","mounts":[{"type":{"virtiofs":{}},"source":"/Users/fix/persist","destination":"/persist","options":[]}]}}]' > "$fixture/apple-hp.json"

apple_mounts() {
    : > "$ALOG"
    M_OUT="$(PATH="$ATOOLS:/usr/bin:/bin" HOME="$fixture/home" DX_RUNTIME=apple dx_runtime_container_mounts "$1" 2>/dev/null)"
    M_RC=$?
}
if type dx_runtime_container_mounts >/dev/null 2>&1; then
    if PATH="$ATOOLS:/usr/bin:/bin" command -v jq >/dev/null 2>&1 && [ "$(command -v jq)" = "$ATOOLS/jq" ]; then
        test_fail "apple: setup error, jq must not be on the fake PATH"
    fi
    apple_mounts dx-vol
    want="$(printf 'bind|/Users/fix/ws|/workspace|ro\nvolume|dx-persist|/persist|rw')"
    if [ "$M_RC" -eq 0 ] && [ "$M_OUT" = "$want" ]; then
        test_pass "apple: compact JSON gives a bind (ro) and a named volume (source = name)"
    else test_fail "apple: compact JSON gives a bind (ro) and a named volume (rc=$M_RC got: $M_OUT)"; fi
    if [ "$(cat "$ALOG")" = 'inspect dx-vol' ]; then
        test_pass "apple: exactly one container call, 'container inspect NAME'"
    else test_fail "apple: exactly one container call, 'container inspect NAME' (got: $(cat "$ALOG"))"; fi
    apple_mounts dx-pretty
    if [ "$M_RC" -eq 0 ] && [ "$M_OUT" = 'volume|dx-persist|/persist|rw' ]; then
        test_pass "apple: pretty-printed JSON is parsed too"
    else test_fail "apple: pretty-printed JSON is parsed too (rc=$M_RC got: $M_OUT)"; fi
    apple_mounts dx-hp
    if [ "$M_RC" -eq 0 ] && [ "$M_OUT" = 'bind|/Users/fix/persist|/persist|rw' ]; then
        test_pass "apple: a host bind reports its absolute source"
    else test_fail "apple: a host bind reports its absolute source (rc=$M_RC got: $M_OUT)"; fi
    apple_mounts dx-gone
    if [ "$M_RC" -ne 0 ] && [ -z "$M_OUT" ]; then
        test_pass "apple: a missing container is non-zero with no output"
    else test_fail "apple: a missing container is non-zero with no output (rc=$M_RC got: $M_OUT)"; fi
else
    test_fail "apple: dx_runtime_container_mounts is available"
fi

# --- 3. dx-status and dx-start-container -------------------------------------
# The entry points are sourced in a probe FILE (BASH_SOURCE is unset in
# `bash -c` under kcov), their runtime-touching functions replaced by
# recording fakes, and their main function called. The probe controls:
#   P_EXISTS (1/0)  P_RUNNING (1/0)  P_MOUNTS (printf %b text)  P_MOUNTS_RC
#   P_MODE (volume|host-path)        and logs to $P_LOG.
cat > "$fixture/probe.sh" <<'PROBE'
#!/bin/bash
set -uo pipefail
entry="$1"; main="$2"
# shellcheck source=/dev/null
source "$entry"
set +e
DX_CONTAINER_NAME=dx-fix DX_PERSIST_VOLUME=dx-fix-persist DX_PERSIST_HOST_ROOT=/fixture-root
DX_PERSIST_STORAGE="$P_MODE"
dx_require_container_cli() { :; }
container_image_exists() { return 1; }
container_exists() { [ "$P_EXISTS" = 1 ]; }
container_is_running() { [ "$P_RUNNING" = 1 ]; }
dx_runtime_logs() { :; }
dx_runtime_container_list() { printf 'dx-fix\tstopped\n'; }
dx_runtime_exec() { :; }
dx_runtime_guest_ssh_address() { echo "no address in this probe" >&2; return 1; }
dx_runtime_container_start() { echo "start $1" >> "$P_LOG"; }
dx_lifecycle_lock_acquire() { :; }
dx_lifecycle_lock_release() { :; }
dx_nix_volume_claim_acquire() { :; }
dx_bootstrap_lease_listing() { :; }
dx_bootstrap_report_drift() { :; }
dx_bootstrap_confirm_publication() { :; }
dx_runtime_container_mounts() {
    echo "mounts $1" >> "$P_LOG"
    [ "$P_MOUNTS_RC" = 0 ] || return "$P_MOUNTS_RC"
    printf '%b' "$P_MOUNTS"
}
# dx-start-container runs "$SCRIPT_DIR/dx-sync-bootstrap"; point it at a stub.
SCRIPT_DIR="$P_STUBDIR"
set -e
"$main"
PROBE

mkdir -p "$fixture/stub"
cat > "$fixture/stub/dx-sync-bootstrap" <<STUB
#!/bin/bash
echo "sync" >> '$fixture/probe.log'
[ "\$1" = --result-file ] && printf 'outcome=unchanged\ngeneration=g1\n' > "\$2"
exit 0
STUB
chmod 0755 "$fixture/stub/dx-sync-bootstrap"

MOUNTS_VOL='bind|/other/nix|/nix|rw\nvolume|dx-fix-persist|/persist|rw\n'
MOUNTS_HP='volume|dx-fix-nix|/nix|rw\nbind|/fixture-root/dxe/dx-fix/persist|/persist|rw\n'

run_probe() { # entry main exists running mode mounts mounts_rc
    : > "$fixture/probe.log"
    PR_OUT="$(env -i HOME="$fixture/home" PATH="/usr/bin:/bin" TMPDIR="$fixture" \
        P_EXISTS="$3" P_RUNNING="$4" P_MODE="$5" P_MOUNTS="$6" P_MOUNTS_RC="$7" \
        P_LOG="$fixture/probe.log" P_STUBDIR="$fixture/stub" \
        bash "$fixture/probe.sh" "$BASE_DIR/bin/$1" "$2" 2>&1)"
    PR_RC=$?
    PR_LOG="$(cat "$fixture/probe.log")"
}
section_of() { # prints the /persist storage section of PR_OUT
    awk '/^--- \/persist storage ---$/ { on = 1; next } /^--- / { on = 0 } on' <<<"$PR_OUT"
}
has_line() { grep -Fqx -- "$2" <<<"$1"; }
status_case() { # label mode exists mounts mounts_rc want_conf want_actual want_mismatch(yes|no)
    local label="$1" sec
    run_probe dx-status status_main "$3" 0 "$2" "$4" "$5"
    sec="$(section_of)"
    if [ "$PR_RC" -eq 0 ] && has_line "$sec" "configured: $6" && has_line "$sec" "actual: $7"; then
        test_pass "status: $label shows configured and actual"
    else test_fail "status: $label shows configured and actual (rc=$PR_RC section: $sec)"; fi
    if [ "$8" = yes ]; then
        if grep -Fq mismatch <<<"$sec" && ! grep -Eiq 'switched|migrated|complete|done' <<<"$sec"; then
            test_pass "status: $label reports a mismatch and never claims the switch is done"
        else test_fail "status: $label reports a mismatch and never claims the switch is done (section: $sec)"; fi
    else
        if [ -n "$sec" ] && ! grep -Fq mismatch <<<"$sec"; then test_pass "status: $label reports no mismatch"
        else test_fail "status: $label reports no mismatch (section: $sec)"; fi
    fi
}

status_case "volume mode, matching" volume 1 "$MOUNTS_VOL" 0 dx-fix-persist dx-fix-persist no
if grep -Fxq 'mounts dx-fix' <<<"$PR_LOG"; then test_pass "status: asks dx_runtime_container_mounts about the container"
else test_fail "status: asks dx_runtime_container_mounts about the container (log: $PR_LOG)"; fi
status_case "host-path mode, matching" host-path 1 "$MOUNTS_HP" 0 /fixture-root/dxe/dx-fix/persist /fixture-root/dxe/dx-fix/persist no
status_case "host-path configured, volume actual" host-path 1 "$MOUNTS_VOL" 0 /fixture-root/dxe/dx-fix/persist dx-fix-persist yes
status_case "volume configured, bind actual" volume 1 "$MOUNTS_HP" 0 dx-fix-persist /fixture-root/dxe/dx-fix/persist yes
status_case "same destination, different source" volume 1 'volume|other-vol|/persist|rw\n' 0 dx-fix-persist other-vol yes
status_case "volume mode, container absent" volume 0 '' 1 dx-fix-persist '(container not present)' no
status_case "host-path mode, container absent" host-path 0 '' 1 /fixture-root/dxe/dx-fix/persist '(container not present)' no

start_case() { # label mode running mounts want_warn(yes|no)
    local label="$1" n
    run_probe dx-start-container start_container_main 1 "$3" "$2" "$4" 0
    n="$(grep -Fc dx-recreate <<<"$PR_OUT")"
    if [ "$5" = yes ]; then
        if [ "$n" -eq 1 ] && grep -F dx-recreate <<<"$PR_OUT" | grep -Fq 'Warning:' \
            && grep -F dx-recreate <<<"$PR_OUT" | grep -Fq 'dx-fix' \
            && grep -F dx-recreate <<<"$PR_OUT" | grep -Fq '/persist' \
            && grep -F dx-recreate <<<"$PR_OUT" | grep -Fq "$6" \
            && grep -F dx-recreate <<<"$PR_OUT" | grep -Fq "$7"; then
            test_pass "start: $label prints exactly one warning naming dx-recreate, the container and both sources"
        else test_fail "start: $label prints exactly one warning (count=$n out: $PR_OUT)"; fi
        if [ "$PR_RC" -eq 0 ] && grep -Fxq sync <<<"$PR_LOG"; then
            test_pass "start: $label warns and carries on (exit 0, bootstrap sync still ran)"
        else test_fail "start: $label warns and carries on (rc=$PR_RC log: $PR_LOG)"; fi
        if [ "$3" = 0 ]; then
            if grep -Fxq 'start dx-fix' <<<"$PR_LOG"; then test_pass "start: $label still starts the stopped container"
            else test_fail "start: $label still starts the stopped container (log: $PR_LOG)"; fi
        fi
    else
        if [ "$n" -eq 0 ] && [ "$PR_RC" -eq 0 ] && grep -Fxq sync <<<"$PR_LOG"; then
            test_pass "start: $label prints no dx-recreate warning"
        else test_fail "start: $label prints no dx-recreate warning (count=$n rc=$PR_RC out: $PR_OUT)"; fi
    fi
}
start_case "stopped, host-path configured but volume actual" host-path 0 "$MOUNTS_VOL" yes /fixture-root/dxe/dx-fix/persist dx-fix-persist
start_case "running, volume configured but bind actual" volume 1 "$MOUNTS_HP" yes dx-fix-persist /fixture-root/dxe/dx-fix/persist
start_case "volume mode, matching" volume 0 "$MOUNTS_VOL" no
start_case "host-path mode, matching" host-path 1 "$MOUNTS_HP" no

print_summary
exit_with_code
