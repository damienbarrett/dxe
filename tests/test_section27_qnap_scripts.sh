#!/bin/bash
# tier: unit
# bash32: yes
# Section 27: QNAP Phase 0 scripts (tests/qnap/phase0-inventory.sh,
# tests/qnap/phase0-spike.sh)
#
# Container-free contracts driven entirely by a stub ssh/docker on PATH --
# there is no NAS to reach yet (qnap-dxe-plan.md Phase 0). Every case here
# proves a safety property from the plan rather than matching source text:
# --dry-run never connects, a real run refuses to proceed past an
# unreachable host, every created/queried resource is scoped to
# "dxe-spike-*" + the "dxe.role=spike" label, --cleanup only ever removes
# what a label-filtered query returned, guarded restarts stay off without
# their flag, a planted secret-shaped string never survives into either
# report, the private summary never carries a path/account name, both
# scripts discover the Docker CLI's absolute path over ssh rather than
# assuming it is on PATH, and both default their (private) report/summary
# paths under $HOME/dxe-recovery/qnap/, never under this repository.
#
# Every stub file path/value below is deliberately generic/fake ("/opt/fake/
# ...") -- never a real QNAP-shaped storage-pool path -- so this file itself
# passes tests/test_section1_secrets.sh's leak scan.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=qnap/lib/phase0-common.sh
source "$SCRIPT_DIR/qnap/lib/phase0-common.sh"

test_section "Section 27: QNAP Phase 0 Scripts"

QNAP_INV="$BASE_DIR/tests/qnap/phase0-inventory.sh"
QNAP_SPIKE="$BASE_DIR/tests/qnap/phase0-spike.sh"

assert_file_exists "$QNAP_INV" "phase0-inventory.sh exists"
assert_file_exists "$QNAP_SPIKE" "phase0-spike.sh exists"
assert_file_exists "$BASE_DIR/tests/qnap/lib/phase0-common.sh" "phase0-common.sh exists"
assert_file_exists "$BASE_DIR/tests/qnap/README.md" "tests/qnap/README.md exists"

for script in "$QNAP_INV" "$QNAP_SPIKE" "$BASE_DIR/tests/qnap/lib/phase0-common.sh"; do
    if bash -n "$script"; then test_pass "$(basename "$script") passes bash syntax"; else test_fail "$(basename "$script") passes bash syntax"; fi
done

# Never a TCP-exposed daemon, never published to the LAN/internet
# (qnap-dxe-plan.md non-goals/Phase 0 safety rule). DQ5 (amended
# 2026-09-26): guest SSH now publishes to the NAS's discovered Tailscale
# address (a variable, so no longer a fixed literal to grep for) rather than
# loopback; the one thing that must never appear literally is 0.0.0.0.
assert_file_not_contains "$QNAP_SPIKE" 'DOCKER_HOST=tcp' "spike never exposes the daemon over TCP"
assert_file_not_contains "$QNAP_SPIKE" '0.0.0.0:2222:2222' "spike never publishes guest port 2222 to all interfaces"

STUB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-stub.XXXXXX")"
MARKER="$(mktemp "${TMPDIR:-/tmp}/dxe-qnap-marker.XXXXXX")"
export MARKER
FAKE_HOME="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-home.XXXXXX")"
rm -f "$MARKER"
cleanup_stub() { rm -rf "$STUB_DIR" "$FAKE_HOME"; rm -f "$MARKER"; }
trap cleanup_stub EXIT

write_stub() {
    local name="$1" body="$2"
    printf '#!/bin/bash\n%s\n' "$body" >"$STUB_DIR/$name"
    chmod +x "$STUB_DIR/$name"
}

reset_marker() { : >"$MARKER"; }

FAKE_DOCKER_BIN="/opt/fake/.qpkg/container-station/bin/docker"
FAKE_TAILSCALE_BIN="/opt/fake/.qpkg/Tailscale/tailscale"
# DQ5 (tailnet-only guest SSH publication, amended 2026-09-26): an RFC 5737
# TEST-NET-3 address, deliberately outside the carrier-grade-NAT /10 block
# Tailscale assigns tailnet addresses from, so this constant can never trip
# test_section1_secrets.sh's TAILNET_IP_PATTERN scan of this (git-tracked)
# file (that pattern matches a 100-dot-sixtyfour-through-127 shape; spelled
# out as digits here, this comment would match it too).
FAKE_TAILNET_ADDR="203.0.113.7"

# A connectable ssh that answers "true"/"reboot"/ss/container-station probes,
# the standalone Docker-path discovery call phase0-spike.sh makes, the
# combined inventory heredoc (including a planted, token-shaped secret and
# an nproc/proc-cpuinfo CPU-count fallback -- the real NAS has no getconf),
# and every "<ssh opts> <host> <fake docker path> <args...>" invocation
# phase0-spike.sh's dxe_qnap_docker_run/_capture make.
write_stub ssh '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    reboot) exit 0 ;;
esac
case "$*" in
    *"ss -ltn"*)
        if [ -n "${DXE_TEST_FAKE_TAILNET_ADDR:-}" ]; then
            printf "LISTEN 0 128 %s:2222 0.0.0.0:*\n" "$DXE_TEST_FAKE_TAILNET_ADDR"
        else
            printf "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*\n"
        fi
        exit 0
        ;;
    *"container-station.sh restart"*) exit 0 ;;
esac
# The standalone Tailscale-address discovery script
# (phase0-spike.sh dxe_qnap_ensure_tailnet_addr): answers with
# DXE_TEST_FAKE_TAILNET_ADDR when a test opts in by setting that env var
# (unset by default, so every real-run test below that does not opt in
# keeps exercising the "address not discovered" fallback path and never
# triggers a real nc/curl network call).
case "$last" in
    *DXE_TAILNET_ADDR*)
        [ -n "${DXE_TEST_FAKE_TAILNET_ADDR:-}" ] && echo "$DXE_TEST_FAKE_TAILNET_ADDR"
        exit 0
        ;;
esac
# The combined inventory heredoc (many DXE_-tagged fields in one script,
# including its own embedded docker/tailscale discovery snippets -- so this
# more specific check must run BEFORE the standalone-discovery check below,
# which would otherwise also match the embedded "DXE_DOCKER_BIN" text below).
case "$last" in
    *DXE_UNAME_M*)
        cat <<OUT
DXE_UNAME_M=x86_64
DXE_UNAME_R=6.6.32-fake
DXE_DOCKER_PATH='"$FAKE_DOCKER_BIN"'
DXE_DOCKER_VERSION_BEGIN
Docker version 27.1.2-fake, build afdd53b
Authorization: Bearer ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234
DXE_DOCKER_VERSION_END
DXE_DOCKER_INFO=ServerVersion=27.1.2 OSType=linux Architecture=x86_64 NCPU=8 MemTotalBytes=16000000000 CgroupDriver=cgroupfs StorageDriver=overlay2
DXE_DOCKER_COMPOSE_VERSION=v5.1.1-fake
DXE_ROOT_DIR_FREE=500000000
DXE_ROOT_DIR_TOTAL=900000000
DXE_ROOT_DIR_PATH=/opt/fake/.qpkg/container-station/data/docker
DXE_ROOT_DIR_POOL=/dev/fake-mapper/pool0
DXE_DIAL_STDIO_EXIT=0
DXE_CPU_COUNT=8
DXE_MEMINFO=MemTotal: 16384000 kB; MemAvailable: 8000000 kB;
DXE_LOADAVG=0.10 0.05 0.01 1/200 1234
DXE_TAILSCALE_PATH='"$FAKE_TAILSCALE_BIN"'
DXE_TAILSCALE_VERSION=1.60.0-fake
DXE_QTS_VERSION=h5.1.0-fake
DXE_CONTAINER_STATION_VERSION=3.0.1-fake
DXE_BACKUP_INDICATION=present (snapshot config file found; not read)
DXE_ACCOUNT_IS_DEFAULT_SUPERUSER=no
DXE_ACCOUNT_IN_ADMIN_GROUP=yes
OUT
        exit 0
        ;;
esac
# The standalone docker-path discovery script (phase0-spike.sh): its last
# line is a lone echo of the discovered path/NOTFOUND, with no other
# DXE_-tagged fields alongside it. Checked only once the more specific
# combined-heredoc case above has already had first refusal.
case "$last" in
    *DXE_DOCKER_BIN*)
        echo "'"$FAKE_DOCKER_BIN"'"
        exit 0
        ;;
esac
# Docker invocation: find the discovered docker path among the args and
# dispatch on the subcommand(s) right after it, exactly like a real
# "ssh <opts> <host> <docker-bin> <docker argv...>" call.
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i
    i=$((i + 1))
done
if [ "$docker_idx" -ge 0 ]; then
    sub="${args[$((docker_idx + 1))]:-}"
    sub2="${args[$((docker_idx + 2))]:-}"
    last_arg="${args[$((${#args[@]} - 1))]:-}"
    case "$sub" in
        version) echo "Docker version 27.1.2-fake, build local"; exit 0 ;;
        pull) echo "digest: sha256:deadbeef"; exit 0 ;;
        inspect) echo "sha256:deadbeef"; exit 0 ;;
        # Real (non-dry-run) step 3 pipes a tar build context into this
        # stub stdin. Drain it before responding -- under pipefail, an
        # unread stdin closes the pipe under tar and kills it with
        # SIGPIPE, which pipefail then promotes to the whole pipeline
        # exit status: a spurious FAIL for a build the stub reports as
        # success. See test_helpers.sh (stdin_matches) for the same bug.
        build) cat >/dev/null; echo "Successfully built"; exit 0 ;;
        volume)
            case "$sub2" in
                create) echo "$last_arg"; exit 0 ;;
                ls) exit 0 ;;
                rm) exit 0 ;;
            esac
            ;;
        run) exit 0 ;;
        exec) exit 0 ;;
        ps) exit 0 ;;
        rm) exit 0 ;;
        image)
            case "$sub2" in ls) exit 0 ;; esac
            ;;
        rmi) exit 0 ;;
        restart) exit 0 ;;
    esac
fi
exit 0
'

# Same ssh stub, but its labelled docker queries (ps -a/volume ls/image ls
# with --filter label=dxe.role=spike) return one container, three volumes,
# and one image, while its *unfiltered* queries additionally return an
# unrelated, non-spike resource -- proving --cleanup only ever acts on the
# label-filtered set, never a blanket listing.
write_stub ssh_with_unrelated '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *DXE_DOCKER_BIN*) echo "'"$FAKE_DOCKER_BIN"'"; exit 0 ;;
esac
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i
    i=$((i + 1))
done
[ "$docker_idx" -ge 0 ] || exit 0
sub="${args[$((docker_idx + 1))]:-}"
sub2="${args[$((docker_idx + 2))]:-}"
has_label_filter=0
for a in "${args[@]}"; do
    [ "$a" = "label=dxe.role=spike" ] && has_label_filter=1
done
case "$sub" in
    ps)
        if [ "$has_label_filter" -eq 1 ]; then echo "dxe-spike-container"; else echo "dxe-spike-container"; echo "some-other-container"; fi
        exit 0
        ;;
    volume)
        case "$sub2" in
            ls)
                if [ "$has_label_filter" -eq 1 ]; then
                    printf "dxe-spike-nix\ndxe-spike-persist\ndxe-spike-bootstrap\n"
                else
                    printf "dxe-spike-nix\ndxe-spike-persist\ndxe-spike-bootstrap\nsome-other-volume\n"
                fi
                exit 0
                ;;
            rm) exit 0 ;;
        esac
        ;;
    image)
        case "$sub2" in
            ls)
                if [ "$has_label_filter" -eq 1 ]; then echo "dxe-spike-image:phase0"; else echo "dxe-spike-image:phase0"; echo "some-other-image:latest"; fi
                exit 0
                ;;
        esac
        ;;
    rm|rmi) exit 0 ;;
esac
exit 0
'

# An ssh stub whose docker pull always fails (step 2), for the "one failing
# step does not abort the run" regression case.
write_stub ssh_step2_fails '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *DXE_DOCKER_BIN*) echo "'"$FAKE_DOCKER_BIN"'"; exit 0 ;;
esac
case "$*" in *"-W 127.0.0.1:2222"*) exit 0 ;; *"ss -ltn"*) echo "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*"; exit 0 ;; esac
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i; i=$((i + 1)); done
[ "$docker_idx" -ge 0 ] || exit 0
sub="${args[$((docker_idx + 1))]:-}"
sub2="${args[$((docker_idx + 2))]:-}"
last_arg="${args[$((${#args[@]} - 1))]:-}"
case "$sub" in
    pull) exit 1 ;;
    volume) case "$sub2" in create) echo "$last_arg"; exit 0 ;; ls|rm) exit 0 ;; esac ;;
    image) case "$sub2" in ls) exit 0 ;; esac ;;
    # Drain the piped tar build context first -- see the same comment on
    # the plain ssh stub above.
    build) cat >/dev/null; exit 0 ;;
    version|inspect|run|exec|ps|rm|rmi|restart) exit 0 ;;
esac
exit 0
'

# An unreachable ssh: every invocation (including the mandatory preflight)
# fails exactly the way OpenSSH reports a transport failure (exit 255).
write_stub ssh_unreachable '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
exit 255
'

# --- Defect 1: step 5's remote docker run survives the ssh hop's own -----
# --- argument-concatenation (regression test for the first real run's    ---
# --- "sh: -c: line 0: syntax error near unexpected token '"'"'then'"'"'"). ---
#
# A real (non-stubbed) ssh, given a destination followed by several
# trailing command-line arguments, concatenates them with a single space
# and hands the result to the remote login shell to parse -- it does not
# preserve whatever quoting the local shell already stripped while
# building that argv. This stub reproduces exactly that behavior (locate
# this run's destination host among its own arguments, then re-run
# everything after it through "sh -c \"\$*\"", the same join-then-reparse
# ssh itself performs) instead of just recording/approving whatever argv
# it was given, so a step whose docker invocation depends on multi-argument
# ssh forwarding to keep an embedded shell script's quoting intact will
# actually fail here the same way it failed for real.
#
# The discovered "Docker CLI" is a real local executable (not the usual
# fake /opt/fake/... path) so that reparsed, argument-preserving
# invocations (every step whose docker arguments are plain tokens) still
# actually run end to end; only an invocation whose quoting does not
# survive the reparse breaks.
FAKE_LOCAL_DOCKER="$STUB_DIR/dxe-fake-docker-exec"
cat >"$FAKE_LOCAL_DOCKER" <<'DOCKEREOF'
#!/bin/bash
sub="$1"
last_arg=""
for dxe_a in "$@"; do last_arg="$dxe_a"; done
case "$sub" in
    version) echo "Docker version 27.1.2-fake, build local" ;;
    pull) echo "digest: sha256:deadbeef" ;;
    inspect) echo "sha256:deadbeef" ;;
    build) cat >/dev/null 2>&1 || true; echo "Successfully built" ;;
    volume)
        case "$2" in
            create) echo "$last_arg" ;;
            ls) : ;;
            rm) : ;;
        esac
        ;;
    run) : ;;
    exec)
        # Records the exact "-c" script text step 6's sha256-verification
        # call ends up with, without actually running anything (no real
        # tar extraction, no real sha256sum -- avoids any side effect on
        # this test machine's real /tmp and any risk of a bare `sha256sum`
        # blocking on stdin if quoting is broken). If the ssh hop's own
        # argument concatenation mangled the "-c" argument, "$#" will not
        # be exactly 3 (sh, -c, <script>) after shifting off exec/-i/the
        # container name, and no line is recorded at all.
        shift
        if [ "${1:-}" = "-i" ]; then shift; fi
        shift
        if [ "${1:-}" = "sh" ] && [ "${2:-}" = "-c" ] && [ "$#" -eq 3 ]; then
            printf 'FAKE_DOCKER_EXEC_SH_C: [%s]\n' "$3" >> "${MARKER:-/dev/null}"
        fi
        cat >/dev/null 2>&1 || true
        ;;
    ps) : ;;
    rm) : ;;
    image) case "$2" in ls) : ;; esac ;;
    rmi) : ;;
    restart) : ;;
esac
exit 0
DOCKEREOF
chmod +x "$FAKE_LOCAL_DOCKER"

write_stub ssh_reparse_command '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
esac
case "$last" in
    *DXE_DOCKER_BIN*) echo "'"$FAKE_LOCAL_DOCKER"'"; exit 0 ;;
esac
case "$*" in
    *"ss -ltn"*) printf "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*\n"; exit 0 ;;
    *"-W 127.0.0.1:2222"*) exit 0 ;;
esac
args=("$@")
host_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "section27-host" ] && host_idx=$i
    i=$((i + 1))
done
if [ "$host_idx" -ge 0 ]; then
    cmd_args=("${args[@]:$((host_idx + 1))}")
    # Fix (fix/test-hardening, open follow-up: fake ssh blocks forever on
    # an open stdin): only "docker exec -i" (step 6'"'"'s real tar-payload
    # stream, piped in locally via "tar ... | ssh ...") ever has genuine
    # local piped content on this stub'"'"'s stdin. Draining unconditionally
    # here for every reparsed subcommand -- run, plain exec, pull,
    # version, tag, ... -- used to also drain THIS WHOLE TEST PROCESS'"'"'s
    # own inherited stdin for every one of those (none of them are
    # locally piped at all), which is a normal instant no-op when that
    # stdin is /dev/null (the standing rule) but blocks forever when it
    # is an open pipe nothing closes (found 2026-09-27: a live-gate run
    # without "</dev/null" sat 22 minutes inside this file). Redirect
    # from /dev/null instead for every other case, so this stub can
    # never block on a stdin it does not own (the fake itself, not the
    # caller).
    if [ "${cmd_args[1]:-}" = exec ] && [ "${cmd_args[2]:-}" = -i ]; then
        cat >/dev/null 2>&1 || true
    else
        exec </dev/null
    fi
    sh -c "${cmd_args[*]}"
    exit $?
fi
exit 0
'

# --- Defect 2: step 9'"'"'s diff guard must not flag the base image step 2 ---
# --- itself pulled as an "unexpected" non-spike change (regression test  ---
# --- for the first real run'"'"'s "Error: unexpected change to a non-spike  ---
# --- resource: > nixos/nix:2.34.7", which then left cleanup'"'"'s own       ---
# --- success obscured by a false FAIL). Stateful: docker'"'"'s unfiltered    ---
# --- image listing (what dxe_spike_snapshot uses) reports the base image ---
# --- only after step 2'"'"'s pull has actually happened, exactly like a real ---
# --- docker daemon would.                                                ---
BASEIMG_PULLED_FLAG="$STUB_DIR/baseimage-pulled.flag"
rm -f "$BASEIMG_PULLED_FLAG"
BASE_REF_FOR_TEST="$(sed -n "s/^FROM //p" "$BASE_DIR/container/dx-nixos-26.05/Containerfile" | head -n1)"
BASE_TAG_FOR_TEST="$(printf "%s" "$BASE_REF_FOR_TEST" | sed "s/@sha256:[0-9a-f]*\$//")"
write_stub ssh_baseimage_diff '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
esac
case "$*" in *"ss -ltn"*) echo "LISTEN 0 128 127.0.0.1:2222 0.0.0.0:*"; exit 0 ;; *"-W 127.0.0.1:2222"*) exit 0 ;; esac
case "$last" in
    *DXE_DOCKER_BIN*) echo "'"$FAKE_DOCKER_BIN"'"; exit 0 ;;
esac
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i
    i=$((i + 1))
done
[ "$docker_idx" -ge 0 ] || exit 0
sub="${args[$((docker_idx + 1))]:-}"
sub2="${args[$((docker_idx + 2))]:-}"
last_arg="${args[$((${#args[@]} - 1))]:-}"
has_label_filter=0
for a in "${args[@]}"; do
    [ "$a" = "label=dxe.role=spike" ] && has_label_filter=1
done
case "$sub" in
    pull) : >"'"$BASEIMG_PULLED_FLAG"'"; exit 0 ;;
    inspect) echo "sha256:deadbeef"; exit 0 ;;
    build) cat >/dev/null; echo "Successfully built"; exit 0 ;;
    version) echo "Docker version 27.1.2-fake, build local"; exit 0 ;;
    volume)
        case "$sub2" in
            create) echo "$last_arg"; exit 0 ;;
            ls)
                if [ "$has_label_filter" -eq 1 ]; then echo "dxe-spike-nix"; else echo "dxe-spike-nix"; fi
                exit 0
                ;;
            rm) exit 0 ;;
        esac
        ;;
    run|exec) exit 0 ;;
    ps)
        echo "dxe-spike-container"
        exit 0
        ;;
    rm) exit 0 ;;
    image)
        case "$sub2" in
            ls)
                if [ "$has_label_filter" -eq 1 ]; then
                    echo "dxe-spike-image:phase0"
                elif [ -e "'"$BASEIMG_PULLED_FLAG"'" ]; then
                    printf "dxe-spike-image:phase0\n'"$BASE_TAG_FOR_TEST"'\n"
                fi
                exit 0
                ;;
        esac
        ;;
    rmi) exit 0 ;;
    restart) exit 0 ;;
esac
exit 0
'

# --- Defect 3: the cleanup loop must remove EVERY labelled resource, not ---
# --- just the first, in one --cleanup run (regression test for the first ---
# --- real run: "removed dxe-spike-nix and stopped; a second labelled     ---
# --- volume remained"). A real ssh session for even a short, stdin-      ---
# --- ignoring remote command commonly still drains whatever the local    ---
# --- side has already buffered on stdin before the remote side closes --  ---
# --- reproduced here (each removal call itself does "cat >/dev/null")    ---
# --- so this stub actually exercises the "while read <<<\"\$list\"; do    ---
# --- ... | ssh ...; done" stdin-theft bug instead of silently passing    ---
# --- because a stub that never touches stdin can'"'"'t reveal it.          ---
write_stub ssh_two_volumes '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *DXE_DOCKER_BIN*) echo "'"$FAKE_DOCKER_BIN"'"; exit 0 ;;
esac
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i
    i=$((i + 1))
done
[ "$docker_idx" -ge 0 ] || exit 0
sub="${args[$((docker_idx + 1))]:-}"
sub2="${args[$((docker_idx + 2))]:-}"
case "$sub" in
    ps) exit 0 ;;
    volume)
        case "$sub2" in
            ls) printf "dxe-spike-vol-a\ndxe-spike-vol-b\n"; exit 0 ;;
            rm) cat >/dev/null 2>&1 || true; exit 0 ;;
        esac
        ;;
    image) case "$sub2" in ls) exit 0 ;; esac ;;
    rm|rmi) cat >/dev/null 2>&1 || true; exit 0 ;;
esac
exit 0
'

# --- pull+tag (user decision, same branch): cleanup must untag the spike --
# --- image BY NAME, since docker tag never attaches the spike label -- a  --
# --- label-filtered-only image query returns nothing for it.             --
write_stub ssh_tag_only_image '
printf "ssh %s\n" "$*" >> "'"$MARKER"'"
last=""
for a in "$@"; do last="$a"; done
case "$last" in
    true) exit 0 ;;
    *DXE_DOCKER_BIN*) echo "'"$FAKE_DOCKER_BIN"'"; exit 0 ;;
esac
args=("$@")
docker_idx=-1
i=0
for a in "${args[@]}"; do
    [ "$a" = "'"$FAKE_DOCKER_BIN"'" ] && docker_idx=$i
    i=$((i + 1))
done
[ "$docker_idx" -ge 0 ] || exit 0
sub="${args[$((docker_idx + 1))]:-}"
sub2="${args[$((docker_idx + 2))]:-}"
has_label_filter=0
for a in "${args[@]}"; do
    [ "$a" = "label=dxe.role=spike" ] && has_label_filter=1
done
case "$sub" in
    ps) exit 0 ;;
    volume) case "$sub2" in ls) exit 0 ;; rm) exit 0 ;; esac ;;
    image)
        case "$sub2" in
            ls)
                # A label-filtered query returns nothing (docker tag never
                # attaches a label); any other query (unfiltered, or
                # filtered by reference) reports the tag, exactly like a
                # real Docker daemon after "docker tag <base> <spike-tag>".
                if [ "$has_label_filter" -eq 1 ]; then
                    :
                else
                    echo "dxe-spike-image:phase0"
                fi
                exit 0
                ;;
        esac
        ;;
    rm|rmi) exit 0 ;;
esac
exit 0
'

# The LOCAL Docker CLI, used only by phase0-inventory.sh's explicit Mac-side
# "docker -H ssh://<alias> ..." naive-mechanism check. Fails by default,
# matching what was confirmed on the real NAS (the remote non-interactive
# shell that transport uses cannot find "docker" either).
write_stub docker '
exit 1
'

# Fake "nc -z -w 5 <addr> <port>", used only by the tailnet-reachability
# tests below (step 7, DQ5). Succeeds only for the address a test opts into
# via DXE_TEST_FAKE_TAILNET_ADDR -- never for a real host, so a run using
# this stub can never make a real network connection.
write_stub nc_ok '
addr="${DXE_TEST_FAKE_TAILNET_ADDR:-}"
[ -n "$addr" ] || exit 1
for a in "$@"; do
    case "$a" in
        "$addr") exit 0 ;;
    esac
done
exit 1
'

# Fake "curl -s --http0.9 --max-time 5 http://<addr>:2222/": emits the
# literal PONG the spike containers listener serves, only for the same
# opted-in fake address.
write_stub curl_ok '
addr="${DXE_TEST_FAKE_TAILNET_ADDR:-}"
[ -n "$addr" ] || exit 1
case "$*" in
    *"$addr:2222"*) printf PONG; exit 0 ;;
esac
exit 1
'

# Fake "nc -z -w 5 <addr> <port>" that FAILS its first call and succeeds
# from the second call onward -- proves step 7'"'"'s bounded retry loop
# actually retries (not just a cosmetic single attempt), the way the real
# listener'"'"'s asynchronous nix-shell fetch requires. Call count is tracked
# in a file (DXE_TEST_NC_RETRY_COUNTER) rather than an env var, since each
# invocation is a fresh process. Never succeeds for any address but the one
# a test opts into.
write_stub nc_retry '
addr="${DXE_TEST_FAKE_TAILNET_ADDR:-}"
counter_file="${DXE_TEST_NC_RETRY_COUNTER:?nc_retry requires DXE_TEST_NC_RETRY_COUNTER}"
[ -n "$addr" ] || exit 1
count=0
[ -f "$counter_file" ] && count="$(cat "$counter_file")"
count=$((count + 1))
printf "%s" "$count" > "$counter_file"
found=0
for a in "$@"; do
    case "$a" in
        "$addr") found=1 ;;
    esac
done
[ "$found" -eq 1 ] || exit 1
[ "$count" -ge 2 ] && exit 0
exit 1
'

run_with_stubs() {
    # $1: space-separated stub names to symlink as ssh/docker for this call;
    # remaining args: the command to run.
    local names="$1"; shift
    local run_dir
    run_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-run.XXXXXX")"
    local n
    for n in $names; do ln -sf "$STUB_DIR/$n" "$run_dir/${n%%_*}"; done
    PATH="$run_dir:$PATH" "$@"
    local status=$?
    rm -rf "$run_dir"
    return $status
}

# Every invocation below explicitly names both --report and --summary under
# $STUB_DIR (never the script's own default) so no test run ever writes into
# the real developer's $HOME -- the one dedicated exception is the "defaults
# are private" case near the end, which overrides HOME to a throwaway
# directory instead.
INV_REPORT="$STUB_DIR/inv-report.md"
INV_SUMMARY="$STUB_DIR/inv-summary.md"
SPIKE_REPORT="$STUB_DIR/spike-report.log"
SPIKE_SUMMARY="$STUB_DIR/spike-summary.md"

# --- (a) --dry-run prints the exact remote command list, never connects ---

reset_marker
inv_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_INV" --dry-run 2>&1)"
if [ ! -s "$MARKER" ]; then test_pass "inventory --dry-run never invokes ssh/docker"; else test_fail "inventory --dry-run never invokes ssh/docker"; fi
if printf '%s' "$inv_dry_out" | stdin_matches -F -- "section27-host" \
    && printf '%s' "$inv_dry_out" | stdin_matches -F -- "uname -m" \
    && printf '%s' "$inv_dry_out" | stdin_matches -F -- "nproc" \
    && printf '%s' "$inv_dry_out" | stdin_matches -F -- "docker -H ssh://section27-host version"; then
    test_pass "inventory --dry-run prints the exact planned remote command list"
else
    test_fail "inventory --dry-run prints the exact planned remote command list"
fi
if printf '%s' "$inv_dry_out" | stdin_matches -F -- "getconf"; then
    test_fail "inventory never uses bare getconf (the real NAS's BusyBox shell has none)"
else
    test_pass "inventory never uses bare getconf (the real NAS's BusyBox shell has none)"
fi

reset_marker
spike_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --dry-run 2>&1)"
if [ ! -s "$MARKER" ]; then test_pass "spike --dry-run never invokes ssh/docker"; else test_fail "spike --dry-run never invokes ssh/docker"; fi
if printf '%s' "$spike_dry_out" | stdin_matches -F -- "DRY-RUN: ssh -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR section27-host \\<discovered-docker-path\\> pull" \
    && printf '%s' "$spike_dry_out" | stdin_matches -F -- "volume create --label dxe.role=spike dxe-spike-nix" \
    && printf '%s' "$spike_dry_out" | stdin_matches -F -- "nc -z -w 5"; then
    test_pass "spike --dry-run prints the exact planned remote command list"
else
    test_fail "spike --dry-run prints the exact planned remote command list"
fi

# --- (a1b) DQ5 (amended 2026-09-26): the NAS's Tailscale address is        ---
# --- discovered over ssh (never hard-coded) via a single script that tries ---
# --- the Tailscale qpkg CLI's "ip -4" first, falling back to reading the   ---
# --- tailscale0 interface directly -- both mechanisms travel in the SAME   ---
# --- one ssh round trip, so whichever actually works on a given NAS is     ---
# --- tried without a second hop. Checked via the dry-run preview text      ---
# --- (the same style as "inventory never uses bare getconf" above) rather  ---
# --- than reading the .sh source directly.                                ---
discovery_block="$(printf '%s\n' "$spike_dry_out" | grep -E -- 'DXE_TAILSCALE_BIN|DXE_TAILNET_ADDR|tailscale0' || true)"
if [ -n "$discovery_block" ] && printf '%s' "$discovery_block" | grep -qE -- 'ip.?-4'; then
    test_pass "spike's tailnet-address discovery tries the Tailscale CLI's ip -4"
else
    test_fail "spike's tailnet-address discovery tries the Tailscale CLI's ip -4"
fi
if [ -n "$discovery_block" ] && printf '%s' "$discovery_block" | stdin_matches -F -- "tailscale0"; then
    test_pass "spike's tailnet-address discovery falls back to the tailscale0 interface"
else
    test_fail "spike's tailnet-address discovery falls back to the tailscale0 interface"
fi

# --- (a1c) step 7's dry-run shows the direct connect/fetch, never ssh -W --
# --- (DQ5: ssh -W/ProxyJump through the NAS is "administratively           -
# --- prohibited" by the NAS's sshd -- AllowTcpForwarding no is the QTS      -
# --- default).                                                             -
step7_block="$(printf '%s\n' "$spike_dry_out" | sed -n '/--- Step 7:/,/--- Step 8:/p')"
if printf '%s' "$step7_block" | stdin_matches -F -- "nc -z -w 5" && printf '%s' "$step7_block" | stdin_matches -F -- "tailnet-ip"; then
    test_pass "step 7's dry-run previews a direct TCP connect to the discovered tailnet address"
else
    test_fail "step 7's dry-run previews a direct TCP connect to the discovered tailnet address"
fi
if printf '%s' "$step7_block" | stdin_matches -F -- "curl" && printf '%s' "$step7_block" | stdin_matches -F -- "2222"; then
    test_pass "step 7's dry-run previews fetching the listener response to check for PONG"
else
    test_fail "step 7's dry-run previews fetching the listener response to check for PONG"
fi
if printf '%s' "$step7_block" | stdin_matches -F -- "-W "; then
    test_fail "step 7's dry-run no longer previews an ssh -W tunnel through the NAS"
else
    test_pass "step 7's dry-run no longer previews an ssh -W tunnel through the NAS"
fi

# --- (a1d) step 7's dry-run shows the bounded retry (the listener now    ---
# --- starts asynchronously -- the nix shell fetch in step 5's command can ---
# --- take a minute or more on a cold /nix store, confirmed locally).      ---
if printf '%s' "$step7_block" | stdin_matches -F -- "poll" \
    && printf '%s' "$step7_block" | stdin_matches -F -- "DXE_QNAP_LISTENER_WAIT_SECONDS" \
    && printf '%s' "$step7_block" | stdin_matches -F -- "180"; then
    test_pass "step 7's dry-run previews the bounded retry (env var and default seconds)"
else
    test_fail "step 7's dry-run previews the bounded retry (env var and default seconds)"
fi

# --- (a1e) step 5's dry-run shows the nix-shell busybox httpd listener, --
# --- never the old busybox/nc/socat fallback chain (regression test for  --
# --- the third real run: the pinned nixos/nix base image has none of      -
# --- busybox/nc/socat/python3/perl, confirmed locally, so that chain      -
# --- always fell through to "exec sleep infinity" and nothing ever        -
# --- listened).                                                           -
# Note: dxe_argv_desc's printf %q reconstruction (same as the
# --with-service-restart comment above) backslash-escapes the spaces inside
# this single-argument remote command string, so multi-word phrases like
# "nix shell" or "sleep infinity" never appear literally -- these checks
# use single, sufficiently distinctive tokens instead.
step5_dry_block="$(printf '%s\n' "$spike_dry_out" | sed -n '/--- Step 5:/,/--- Step 6:/p')"
if printf '%s' "$step5_dry_block" | stdin_matches -F -- "nixpkgs#busybox" \
    && printf '%s' "$step5_dry_block" | stdin_matches -F -- "busybox" \
    && printf '%s' "$step5_dry_block" | stdin_matches -F -- "httpd"; then
    test_pass "step 5's dry-run shows the nix shell busybox httpd listener command"
else
    test_fail "step 5's dry-run shows the nix shell busybox httpd listener command"
fi
if printf '%s' "$step5_dry_block" | stdin_matches -F -- "nix-command" \
    && printf '%s' "$step5_dry_block" | stdin_matches -F -- "flakes"; then
    test_pass "step 5's dry-run shows --extra-experimental-features \"nix-command flakes\""
else
    test_fail "step 5's dry-run shows --extra-experimental-features \"nix-command flakes\""
fi
if printf '%s' "$step5_dry_block" | stdin_matches -F -- "sleep" \
    && printf '%s' "$step5_dry_block" | stdin_matches -F -- "infinity"; then
    test_pass "step 5's dry-run still shows exec sleep infinity as the last-resort fallback"
else
    test_fail "step 5's dry-run still shows exec sleep infinity as the last-resort fallback"
fi
if printf '%s' "$step5_dry_block" | stdin_matches -F -- "nc -l" \
    || printf '%s' "$step5_dry_block" | stdin_matches -F -- "socat"; then
    test_fail "step 5's dry-run no longer shows the old nc -l/socat fallback chain"
else
    test_pass "step 5's dry-run no longer shows the old nc -l/socat fallback chain"
fi

# --- (a2) step 3 tags the pulled base image instead of building remotely ---
# --- (user decision: QNAP's Docker wrapper refuses the per-user build     ---
# --- directory under Container Station's data area for a non-default     ---
# --- administrator -- "mkdir .../container-station/homes/<user>:         ---
# --- permission denied" -- and the Containerfile is a single FROM line,   ---
# --- so a remote build added nothing but a name).                        ---

step3_block="$(printf '%s\n' "$spike_dry_out" | sed -n '/--- Step 3:/,/--- Step 4:/p')"
step3_commands="$(printf '%s\n' "$step3_block" | grep -E '^DRY-RUN:' || true)"
step3_tag_line="$(printf '%s\n' "$step3_commands" | grep -E -- ' tag ' | head -n1)"

if printf '%s' "$step3_commands" | stdin_matches -F -- ' build '; then
    test_fail "step 3 never issues a remote docker build (replaced by pull+tag)"
else
    test_pass "step 3 never issues a remote docker build (replaced by pull+tag)"
fi

if [ -n "$step3_tag_line" ]; then
    test_pass "step 3's dry-run output includes a docker tag command"
else
    test_fail "step 3's dry-run output includes a docker tag command"
fi

if printf '%s' "$step3_tag_line" | stdin_matches -F -- "$BASE_REF_FOR_TEST" \
    && printf '%s' "$step3_tag_line" | stdin_matches -F -- 'dxe-spike-image:phase0'; then
    test_pass "step 3 tags the FROM-line-parsed base reference as dxe-spike-image:phase0"
else
    test_fail "step 3 tags the FROM-line-parsed base reference as dxe-spike-image:phase0"
fi

if printf '%s' "$step3_block" | stdin_matches -F -- '/Users/' \
    || printf '%s' "$step3_block" | stdin_matches -F -- "$HOME" \
    || printf '%s' "$step3_block" | stdin_matches -F -- "$BASE_DIR"; then
    test_fail "step 3 never names a local Mac path (no build context needed any more)"
else
    test_pass "step 3 never names a local Mac path (no build context needed any more)"
fi

# --- (a3) cleanup untags the spike image by name, since docker tag never --
# --- attaches a label (regression test for the same-day pull+tag change; ---
# --- a label-filtered-only cleanup would silently leave this tag behind). -
reset_marker
set +e
run_with_stubs "ssh_tag_only_image docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/cleanup_tagonly_out.log" 2>&1
set -e
if grep -qF -- 'rmi dxe-spike-image:phase0' "$MARKER"; then
    test_pass "cleanup untags the spike image by name even when no image carries the spike label"
else
    test_fail "cleanup untags the spike image by name even when no image carries the spike label"
fi

# --- (b) refuses to run without DXE_QNAP_HOST reachable, before mutation ---

reset_marker
set +e
run_with_stubs "ssh_unreachable docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/refuse_out.log" 2>&1
refuse_status=$?
set -e
refuse_out="$(cat "$STUB_DIR/refuse_out.log")"
if [ "$refuse_status" -ne 0 ]; then test_pass "spike exits non-zero when the host is unreachable"; else test_fail "spike exits non-zero when the host is unreachable"; fi
if printf '%s' "$refuse_out" | stdin_matches -F -- "cannot reach" && printf '%s' "$refuse_out" | stdin_matches -F -- "section27-host"; then
    test_pass "spike prints a clear unreachable-host error naming the host alias"
else
    test_fail "spike prints a clear unreachable-host error naming the host alias"
fi
if [ "$(grep -c '^ssh ' "$MARKER" || true)" -eq 1 ]; then
    test_pass "spike issues only the reachability preflight before refusing -- no further ssh call"
else
    test_fail "spike issues only the reachability preflight before refusing -- no further ssh call"
fi

# --- (c) every docker create/run/volume-create invocation in dry-run output ---
# --- carries the dxe-spike- name prefix and the dxe.role=spike label      ---

creation_lines="$(printf '%s\n' "$spike_dry_out" | grep -E 'DRY-RUN:.*(volume create|run -d)' || true)"
if [ -n "$creation_lines" ]; then
    all_scoped=1
    while IFS= read -r line; do
        case "$line" in
            *"$DXE_SPIKE_PREFIX"*"$DXE_SPIKE_LABEL"*) ;;
            *"$DXE_SPIKE_LABEL"*"$DXE_SPIKE_PREFIX"*) ;;
            *) all_scoped=0 ;;
        esac
    done <<<"$creation_lines"
    if [ "$all_scoped" -eq 1 ]; then
        test_pass "every dry-run volume-create/run invocation carries the dxe-spike- prefix and dxe.role=spike label"
    else
        test_fail "every dry-run volume-create/run invocation carries the dxe-spike- prefix and dxe.role=spike label"
    fi
else
    test_fail "dry-run output contains at least one volume-create/run invocation to check"
fi

# Behavioral (not source-text) proof that the actual disposable-container
# create command never asks for --privileged or CAP_SYS_ADMIN: grepping the
# whole source file would also match this script's own "no --privileged, no
# CAP_SYS_ADMIN" step-5 description text, so check the real planned argv
# instead.
run_line="$(printf '%s\n' "$spike_dry_out" | grep -E 'DRY-RUN:.*run -d' || true)"
if [ -n "$run_line" ] && ! printf '%s' "$run_line" | stdin_matches -F -- '--privileged' && ! printf '%s' "$run_line" | stdin_matches -F -- 'CAP_SYS_ADMIN'; then
    test_pass "the disposable container's run command never adds --privileged or CAP_SYS_ADMIN"
else
    test_fail "the disposable container's run command never adds --privileged or CAP_SYS_ADMIN"
fi

# --- (d) --cleanup only issues removals for labelled resources ------------

reset_marker
set +e
run_with_stubs "ssh_with_unrelated docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/cleanup_out.log" 2>&1
cleanup_status=$?
set -e
if [ "$cleanup_status" -eq 0 ]; then test_pass "spike --cleanup exits 0 against a reachable host"; else test_fail "spike --cleanup exits 0 against a reachable host"; fi

if grep -q -- '--filter label=dxe.role=spike' "$MARKER"; then
    test_pass "--cleanup queries are scoped by label=dxe.role=spike, not a blanket listing"
else
    test_fail "--cleanup queries are scoped by label=dxe.role=spike, not a blanket listing"
fi
for expect in 'rm -f dxe-spike-container' 'volume rm dxe-spike-nix' 'volume rm dxe-spike-persist' 'volume rm dxe-spike-bootstrap' 'rmi dxe-spike-image:phase0'; do
    if grep -qF -- "$expect" "$MARKER"; then test_pass "--cleanup removes labelled resource: $expect"; else test_fail "--cleanup removes labelled resource: $expect"; fi
done
for forbidden in 'rm -f some-other-container' 'volume rm some-other-volume' 'rmi some-other-image:latest'; do
    if grep -qF -- "$forbidden" "$MARKER"; then test_fail "--cleanup never touches unrelated resource: $forbidden"; else test_pass "--cleanup never touches unrelated resource: $forbidden"; fi
done

# --cleanup is idempotent: nothing labelled left means nothing removed, exit 0.
reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/cleanup_empty_out.log" 2>&1
cleanup_empty_status=$?
set -e
cleanup_empty_out="$(cat "$STUB_DIR/cleanup_empty_out.log")"
if [ "$cleanup_empty_status" -eq 0 ] && printf '%s' "$cleanup_empty_out" | stdin_matches -F -- "No labelled containers to remove."; then
    test_pass "--cleanup with nothing labelled left is idempotent (exit 0, no removals)"
else
    test_fail "--cleanup with nothing labelled left is idempotent (exit 0, no removals)"
fi

# --- (e) reboot/service restarts are skipped without their flags -----------

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/norestart_out.log" 2>&1
set -e
norestart_out="$(cat "$STUB_DIR/norestart_out.log")"
if printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8a: SKIP" \
    && printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8b: SKIP" \
    && printf '%s' "$norestart_out" | stdin_matches -F -- "Step 8c: SKIP"; then
    test_pass "steps 8a/8b/8c report SKIP without their flags"
else
    test_fail "steps 8a/8b/8c report SKIP without their flags"
fi
if grep -qE ' reboot$' "$MARKER"; then
    test_fail "no reboot command is ever issued without --with-nas-reboot"
else
    test_pass "no reboot command is ever issued without --with-nas-reboot"
fi
if grep -q 'restart dxe-spike-container' "$MARKER" || grep -q 'container-station.sh restart' "$MARKER"; then
    test_fail "no restart command is ever issued without --with-container-restart/--with-service-restart"
else
    test_pass "no restart command is ever issued without --with-container-restart/--with-service-restart"
fi

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --with-container-restart --with-service-restart --with-nas-reboot --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/withrestart_out.log" 2>&1
set -e
if grep -q 'restart dxe-spike-container' "$MARKER"; then test_pass "--with-container-restart issues the container restart"; else test_fail "--with-container-restart issues the container restart"; fi
if grep -q 'container-station.sh restart' "$MARKER"; then test_pass "--with-service-restart issues the Container Station restart"; else test_fail "--with-service-restart issues the Container Station restart"; fi
if grep -qE ' reboot$' "$MARKER"; then test_pass "--with-nas-reboot issues the NAS reboot"; else test_fail "--with-nas-reboot issues the NAS reboot"; fi

# --- (e2) 8a/8b/8c are independently gated: each flag triggers only its ---
# --- own restart and leaves the other two reported as skipped            ---
# --- (regression test for splitting the previously-shared               ---
# --- --with-service-restart flag into --with-container-restart (8a)     ---
# --- and --with-service-restart (8b)).                                  ---

reset_marker
set +e
container_only_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --dry-run --with-container-restart 2>&1)"
set -e
if printf '%s' "$container_only_dry_out" | stdin_matches -F -- "restart dxe-spike-container"; then
    test_pass "--with-container-restart alone shows the container restart command in dry-run"
else
    test_fail "--with-container-restart alone shows the container restart command in dry-run"
fi
if printf '%s' "$container_only_dry_out" | stdin_matches -F -- "Step 8a: SKIP"; then
    test_fail "--with-container-restart alone does not leave 8a itself skipped"
else
    test_pass "--with-container-restart alone does not leave 8a itself skipped"
fi
if printf '%s' "$container_only_dry_out" | stdin_matches -F -- "Step 8b: SKIP" \
    && printf '%s' "$container_only_dry_out" | stdin_matches -F -- "Step 8c: SKIP"; then
    test_pass "--with-container-restart alone leaves 8b (Container Station) and 8c (reboot) skipped"
else
    test_fail "--with-container-restart alone leaves 8b (Container Station) and 8c (reboot) skipped"
fi
if printf '%s' "$container_only_dry_out" | stdin_matches -F -- "container-station.sh"; then
    test_fail "--with-container-restart alone never previews the Container Station restart command"
else
    test_pass "--with-container-restart alone never previews the Container Station restart command"
fi

reset_marker
set +e
service_only_dry_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --dry-run --with-service-restart 2>&1)"
set -e
# Note: dxe_maybe_run's dry-run preview reconstructs argv with printf %q,
# which backslash-escapes the space inside this single-argument remote
# command string ("container-station.sh\ restart") -- so this checks the
# command name alone rather than the exact (correctly working) real text.
if printf '%s' "$service_only_dry_out" | stdin_matches -F -- "container-station.sh"; then
    test_pass "--with-service-restart alone shows the Container Station restart command in dry-run"
else
    test_fail "--with-service-restart alone shows the Container Station restart command in dry-run"
fi
if printf '%s' "$service_only_dry_out" | stdin_matches -F -- "Step 8b: SKIP"; then
    test_fail "--with-service-restart alone does not leave 8b itself skipped"
else
    test_pass "--with-service-restart alone does not leave 8b itself skipped"
fi
if printf '%s' "$service_only_dry_out" | stdin_matches -F -- "Step 8a: SKIP" \
    && printf '%s' "$service_only_dry_out" | stdin_matches -F -- "Step 8c: SKIP"; then
    test_pass "--with-service-restart alone leaves 8a (container) and 8c (reboot) skipped"
else
    test_fail "--with-service-restart alone leaves 8a (container) and 8c (reboot) skipped"
fi
if printf '%s' "$service_only_dry_out" | stdin_matches -F -- "restart dxe-spike-container"; then
    test_fail "--with-service-restart alone never previews the container restart command"
else
    test_pass "--with-service-restart alone never previews the container restart command"
fi

# --- (f) redaction: a planted token-like string never survives into either ---
# --- inventory report; the summary additionally never carries a path/name ---

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_INV" --report "$INV_REPORT" --summary "$INV_SUMMARY" >/dev/null 2>&1
inv_status=$?
set -e
if [ "$inv_status" -eq 0 ]; then test_pass "inventory exits 0 against a reachable host"; else test_fail "inventory exits 0 against a reachable host"; fi
assert_file_exists "$INV_REPORT" "inventory writes a full report file"
assert_file_exists "$INV_SUMMARY" "inventory writes a summary file"
for f in "$INV_REPORT" "$INV_SUMMARY"; do
    if grep -qF -- 'ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef1234' "$f"; then
        test_fail "the planted token-like string is redacted from $(basename "$f")"
    else
        test_pass "the planted token-like string is redacted from $(basename "$f")"
    fi
done
assert_file_contains_literal "$INV_REPORT" '[REDACTED' "the full report carries a redaction marker in its place"
assert_file_contains_literal "$INV_REPORT" 'Host alias:' "the full report header names the host alias"
assert_file_contains_literal "$INV_REPORT" 'Commit:' "the full report header names the script's git commit"
if grep -qF -- "$FAKE_DOCKER_BIN" "$INV_SUMMARY"; then
    test_fail "the summary never carries the discovered Docker CLI path"
else
    test_pass "the summary never carries the discovered Docker CLI path"
fi
assert_file_contains_literal "$INV_SUMMARY" 'A non-default administrator account can run Docker non-interactively: yes' "the summary answers the non-default-admin-docker question without an account name"

# --- Spike's --summary is step verdicts + prefix only, never a path -------

reset_marker
set +e
run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >/dev/null 2>&1
set -e
assert_file_exists "$SPIKE_REPORT" "spike writes a full report file"
assert_file_exists "$SPIKE_SUMMARY" "spike writes a summary file"
if grep -qF -- "$FAKE_DOCKER_BIN" "$SPIKE_SUMMARY"; then
    test_fail "spike's summary never carries the discovered Docker CLI path"
else
    test_pass "spike's summary never carries the discovered Docker CLI path"
fi
if grep -qE '^Step [A-Za-z0-9-]+: (PASS|FAIL|SKIP)$' "$SPIKE_SUMMARY"; then
    test_pass "spike's summary lines are bare step verdicts with no detail"
else
    test_fail "spike's summary lines are bare step verdicts with no detail"
fi
if grep -qF -- "$FAKE_DOCKER_BIN" "$SPIKE_REPORT"; then
    test_pass "spike's full report may still record the discovered path (private file)"
else
    test_fail "spike's full report may still record the discovered path (private file)"
fi

# --- Both scripts default their reports OUTSIDE the repository -----------
#
# HOME is overridden to a throwaway directory for this one case (never the
# real developer $HOME) precisely so this test can observe the *default*
# path without ever writing into anyone's real ~/dxe-recovery/qnap/.
reset_marker
set +e
HOME="$FAKE_HOME" run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host HOME="$FAKE_HOME" "$QNAP_INV" >/dev/null 2>&1
set -e
if find "$FAKE_HOME/dxe-recovery/qnap" -type f -name '*.md' 2>/dev/null | stdin_matches .; then
    test_pass "inventory's default report/summary paths land outside the repository (under \$HOME/dxe-recovery/qnap/)"
else
    test_fail "inventory's default report/summary paths land outside the repository (under \$HOME/dxe-recovery/qnap/)"
fi
if find "$BASE_DIR/docs/evidence/qnap" -type f 2>/dev/null | stdin_matches .; then
    test_fail "inventory never defaults into docs/evidence/qnap/ (repository)"
else
    test_pass "inventory never defaults into docs/evidence/qnap/ (repository)"
fi

# --- A single failing step reports FAIL and does not abort the run --------
#
# The spike script runs under its own `set -euo pipefail`. Every step calls
# a function whose last command is the real ssh/docker invocation, so a
# bare "cmd; step_verdict "$?"" pair would make the *first* failing step
# kill the whole script before it could ever print FAIL or reach later
# steps/cleanup -- exactly the bug this test caught by hand while writing
# phase0-spike.sh (see the branch progress file). Force step 2's base-image
# pull to fail and confirm steps 3-9 still run and the run still exits
# non-zero (not merely "some assertion never ran").
reset_marker
set +e
run_with_stubs "ssh_step2_fails docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/step2fail_out.log" 2>&1
step2fail_status=$?
set -e
step2fail_out="$(cat "$STUB_DIR/step2fail_out.log")"
if [ "$step2fail_status" -ne 0 ]; then
    test_pass "a failing step still exits the run non-zero overall"
else
    test_fail "a failing step still exits the run non-zero overall"
fi
if printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 2: FAIL"; then
    test_pass "the failing step is reported as FAIL rather than aborting silently"
else
    test_fail "the failing step is reported as FAIL rather than aborting silently"
fi
if printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 5: PASS" && printf '%s' "$step2fail_out" | stdin_matches -F -- "Step 9:"; then
    test_pass "steps after a failing step still run (no set -e abort mid-run)"
else
    test_fail "steps after a failing step still run (no set -e abort mid-run)"
fi

# --- Defect 1: step 5's docker run must survive ssh's own argument --------
# --- concatenation (regression test for "sh: -c: line 0: syntax error    ---
# --- near unexpected token 'then'" on the first real run).                ---
reset_marker
set +e
d1_out="$(run_with_stubs "ssh_reparse_command docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" 2>&1)"
set -e
step5_block="$(printf '%s\n' "$d1_out" | sed -n '/--- Step 5:/,/--- Step 6:/p')"
if printf '%s' "$step5_block" | stdin_matches -F -- 'Step 5: PASS'; then
    test_pass "step 5's docker run survives the ssh hop's own argument concatenation"
else
    test_fail "step 5's docker run survives the ssh hop's own argument concatenation"
fi
if printf '%s' "$step5_block" | stdin_matches -F -- 'unexpected token'; then
    test_fail "step 5 never reproduces the remote shell's \"unexpected token\" syntax error"
else
    test_pass "step 5 never reproduces the remote shell's \"unexpected token\" syntax error"
fi

# --- Defect (same class): step 6's sha256-verification exec must also ----
# --- survive the ssh hop's own argument concatenation -- its "-c" script  --
# --- has the same shape (spaces, ||, redirects) as step 5's, just less    --
# --- loudly broken (a silent hash mismatch, not a hard syntax error).     --
# --- Reuses the same full run/stub above (ssh_reparse_command's fake      --
# --- docker records the exact "-c" argument it receives, without really  --
# --- running anything).                                                  ---
if grep -qF -- 'FAKE_DOCKER_EXEC_SH_C: [sha256sum /tmp/payload.txt 2>/dev/null || shasum -a 256 /tmp/payload.txt]' "$MARKER"; then
    test_pass "step 6's sha256-verification exec survives the ssh hop's own argument concatenation"
else
    test_fail "step 6's sha256-verification exec survives the ssh hop's own argument concatenation"
fi

# --- Open follow-up (found 2026-09-27): a live-gate script ran ------------
# --- "tests/run-tier.sh live" without "</dev/null", and this file's own    -
# --- fake ssh then blocked forever -- the tier sat 22 minutes inside this  -
# --- file, and two stale copies of the same test from an earlier run were -
# --- found hung the same way. The standing "stdin from /dev/null" rule    -
# --- every OTHER invocation in this file honours masks the bug: with a    -
# --- closed stdin, an unconditional "cat >/dev/null" drain (ssh_reparse_  -
# --- command's own, run before it reparses ANY docker subcommand via      -
# --- "sh -c", not just the one -- "docker exec -i", step 6's real tar-    -
# --- payload stream -- that ever has genuine local piped content) returns -
# --- instantly. With an inherited stdin that is an open pipe nothing ever -
# --- closes, that same drain blocks forever on every OTHER subcommand     -
# --- (run, exec without -i, pull, version, tag, ...), because their ssh   -
# --- call is never locally piped into at all -- their stdin IS whatever   -
# --- this whole test process inherited. Invokes the stub DIRECTLY (a      -
# --- plain "docker version" call, ssh_reparse_command's own shape for     -
# --- every non-"exec -i" subcommand) rather than through the whole spike  -
# --- script: exactly the vulnerable code path, one single process, no     -
# --- descendant tree to track or clean up. Bounded: this test must never  -
# --- itself hang the suite, so it backgrounds the call behind a real pipe -
# --- held open read-write (never closes on its own) and polls with a hard -
# --- kill past the bound -- the deliberate, documented exception to       -
# --- "every test invocation gets stdin from /dev/null" (this IS the case  -
# --- under test). Fixed-fd redirection only ("exec 9<>", not "exec {fd}<>"--
# --- ): this file runs directly under real Bash 3.2 (run-bash32-tests.sh).-
reset_marker
OPEN_STDIN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-qnap-openstdin.XXXXXX")"
OPEN_STDIN_FIFO="$OPEN_STDIN_DIR/fifo"
mkfifo "$OPEN_STDIN_FIFO"
# Opened read-write (not read-only) so THIS shell also holds the write end
# open: a read-only opener would see EOF the instant nothing else has it
# open for writing, which is exactly the "closes on its own" shape this
# test must NOT reproduce.
exec 9<>"$OPEN_STDIN_FIFO"
# set +e/-e (this file's own idiom, e.g. just above at lines 1112/1114):
# a killed or timed-out background job's "wait" status is expected to be
# non-zero here -- that is the very thing under test -- and a bare
# non-zero statement under this file's earlier "set -e" (still active
# since line 1114, with no matching "set +e" before this point) would
# abort the WHOLE script on that status instead of letting this one test
# report it normally.
set +e
(
    "$STUB_DIR/ssh_reparse_command" -o BatchMode=yes -o ConnectTimeout=10 -o LogLevel=ERROR section27-host "$FAKE_LOCAL_DOCKER" version
) <&9 >"$STUB_DIR/openstdin_out.log" 2>&1 &
open_stdin_pid=$!
open_stdin_bound=20
open_stdin_waited=0
while [ "$open_stdin_waited" -lt "$open_stdin_bound" ] && kill -0 "$open_stdin_pid" 2>/dev/null; do
    sleep 1
    open_stdin_waited=$((open_stdin_waited + 1))
done
if kill -0 "$open_stdin_pid" 2>/dev/null; then
    kill -9 "$open_stdin_pid" 2>/dev/null
    wait "$open_stdin_pid" 2>/dev/null
    open_stdin_status=124
else
    wait "$open_stdin_pid" 2>/dev/null
    open_stdin_status=$?
fi
set -e
exec 9<&-
rm -rf "$OPEN_STDIN_DIR"
if [ "$open_stdin_status" -eq 0 ] && grep -qF 'Docker version' "$STUB_DIR/openstdin_out.log" 2>/dev/null; then
    test_pass "Section 27's fake ssh completes within ${open_stdin_bound}s even when this whole test process's own stdin is an open pipe that never closes"
else
    test_fail "Section 27's fake ssh completes within ${open_stdin_bound}s even when this whole test process's own stdin is an open pipe that never closes (status=$open_stdin_status, out: $(cat "$STUB_DIR/openstdin_out.log" 2>/dev/null))"
fi

# --- Defect 2: step 9's diff guard must not flag step 2's own base-image --
# --- pull as an "unexpected" non-spike change, and cleanup must still     -
# --- fully complete regardless of the guard's verdict (regression test    -
# --- for "Error: unexpected change to a non-spike resource: >             -
# --- nixos/nix:2.34.7" on the first real run).                            -
reset_marker
set +e
run_with_stubs "ssh_baseimage_diff docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/baseimage_out.log" 2>&1
set -e
baseimage_out="$(cat "$STUB_DIR/baseimage_out.log")"
if printf '%s' "$baseimage_out" | stdin_matches -F -- "unexpected change to a non-spike resource: > $BASE_TAG_FOR_TEST"; then
    test_fail "step 9's diff guard does not flag step 2's own base-image pull as unexpected"
else
    test_pass "step 9's diff guard does not flag step 2's own base-image pull as unexpected"
fi
if grep -qF -- 'volume rm dxe-spike-nix' "$MARKER"; then
    test_pass "cleanup still removes labelled resources even when the diff guard is exercised"
else
    test_fail "cleanup still removes labelled resources even when the diff guard is exercised"
fi

# --- Defect 3: --cleanup must remove EVERY labelled volume in one run, ----
# --- not just the first (regression test for "removed dxe-spike-nix and  -
# --- stopped; a second labelled volume remained" on the first real run). -
reset_marker
set +e
run_with_stubs "ssh_two_volumes docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --cleanup --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" >"$STUB_DIR/cleanup_twovol_out.log" 2>&1
set -e
if grep -qF -- 'volume rm dxe-spike-vol-a' "$MARKER"; then
    test_pass "--cleanup removes the first of two labelled volumes"
else
    test_fail "--cleanup removes the first of two labelled volumes"
fi
if grep -qF -- 'volume rm dxe-spike-vol-b' "$MARKER"; then
    test_pass "--cleanup removes the second of two labelled volumes in the same run (not just the first)"
else
    test_fail "--cleanup removes the second of two labelled volumes in the same run (not just the first)"
fi

# --- Inventory: the Docker Root Dir's pool is recorded separately from ----
# --- the qpkg path, in the private full report only, never the summary. --
if grep -qF -- '/opt/fake/.qpkg/container-station/data/docker' "$INV_REPORT" \
    && grep -qF -- '/dev/fake-mapper/pool0' "$INV_REPORT"; then
    test_pass "the full inventory report records both the Docker Root Dir path and its (separate) pool"
else
    test_fail "the full inventory report records both the Docker Root Dir path and its (separate) pool"
fi
if grep -qF -- '/dev/fake-mapper/pool0' "$INV_SUMMARY" || grep -qF -- '/opt/fake/.qpkg/container-station/data/docker' "$INV_SUMMARY" || grep -qF -- 'Docker Root Dir' "$INV_SUMMARY"; then
    test_fail "the inventory summary never mentions the Docker Root Dir path/pool"
else
    test_pass "the inventory summary never mentions the Docker Root Dir path/pool"
fi

# --- DQ5 (amended 2026-09-26): guest SSH publishes to the NAS's own        ---
# --- discovered Tailscale address only, never loopback/LAN/0.0.0.0, and    ---
# --- the controller connects to it directly (no ssh -W/ProxyJump, which    ---
# --- the real NAS's sshd refuses by default). Two real (non-dry-run)       ---
# --- scenarios: the default stubs never answer the address-discovery call -
# --- (fallback path, exercised by every other real-run test above without -
# --- any change in behavior), and a dedicated opt-in scenario where the    -
# --- address IS discovered, proving step 5/7 use it correctly -- with      -
# --- nc/curl themselves stubbed (nc_ok/curl_ok, gated on the same env var) -
# --- so this stays fully hermetic: no real network I/O even in the happy   -
# --- path.                                                                 -

# (g1) fallback: address not discovered -> step 5 publishes 127.0.0.1 only,
# step 7 reports FAIL with a clear reason, never touching nc/curl.
reset_marker
set +e
fallback_out="$(run_with_stubs "ssh docker" env DXE_QNAP_HOST=section27-host "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" 2>&1)"
set -e
if printf '%s' "$fallback_out" | stdin_matches -F -- "Step 5: PASS" \
    && printf '%s' "$fallback_out" | stdin_matches -F -- "fell back to loopback-only publication"; then
    test_pass "step 5 falls back to loopback-only publication when the tailnet address is not discovered"
else
    test_fail "step 5 falls back to loopback-only publication when the tailnet address is not discovered"
fi
if grep -qF -- '-p 127.0.0.1:2222:2222' "$MARKER"; then
    test_pass "the fallback container run publishes -p 127.0.0.1:2222:2222 (not 0.0.0.0, not a stale tailnet value)"
else
    test_fail "the fallback container run publishes -p 127.0.0.1:2222:2222 (not 0.0.0.0, not a stale tailnet value)"
fi
if printf '%s' "$fallback_out" | stdin_matches -F -- "Step 7: FAIL" \
    && printf '%s' "$fallback_out" | stdin_matches -F -- "could not be discovered"; then
    test_pass "step 7 reports FAIL with a clear reason when the tailnet address was not discovered"
else
    test_fail "step 7 reports FAIL with a clear reason when the tailnet address was not discovered"
fi

# (g2) happy path: address discovered -> step 5 publishes it (never
# 0.0.0.0), step 7 confirms tailnet-only binding and direct reachability.
reset_marker
set +e
tailnet_ok_out="$(run_with_stubs "ssh docker nc_ok curl_ok" env DXE_QNAP_HOST=section27-host DXE_TEST_FAKE_TAILNET_ADDR="$FAKE_TAILNET_ADDR" "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" 2>&1)"
set -e
if printf '%s' "$tailnet_ok_out" | stdin_matches -F -- "Step 5: PASS"; then
    test_pass "step 5 succeeds when the tailnet address is discovered"
else
    test_fail "step 5 succeeds when the tailnet address is discovered"
fi
if grep -qF -- "-p $FAKE_TAILNET_ADDR:2222:2222" "$MARKER"; then
    test_pass "step 5 publishes to the discovered tailnet address, not loopback"
else
    test_fail "step 5 publishes to the discovered tailnet address, not loopback"
fi
if grep -qF -- '0.0.0.0:2222:2222' "$MARKER"; then
    test_fail "step 5 never publishes to 0.0.0.0 even when the tailnet address is known"
else
    test_pass "step 5 never publishes to 0.0.0.0 even when the tailnet address is known"
fi
if printf '%s' "$tailnet_ok_out" | stdin_matches -F -- "Step 7: PASS" \
    && printf '%s' "$tailnet_ok_out" | stdin_matches -F -- "PONG confirmed"; then
    test_pass "step 7 confirms tailnet-only binding and direct PONG reachability when the address is discovered"
else
    test_fail "step 7 confirms tailnet-only binding and direct PONG reachability when the address is discovered"
fi

# (g3) the private report may record the discovered address (same rule as
# the discovered Docker CLI path); the summary must never contain it.
if grep -qF -- "$FAKE_TAILNET_ADDR" "$SPIKE_REPORT"; then
    test_pass "the private full report may record the discovered tailnet address"
else
    test_fail "the private full report may record the discovered tailnet address"
fi
if grep -qF -- "$FAKE_TAILNET_ADDR" "$SPIKE_SUMMARY"; then
    test_fail "the spike summary never contains the discovered tailnet address"
else
    test_pass "the spike summary never contains the discovered tailnet address"
fi

# (g4) step 7's bounded retry actually retries: the fake direct-connect
# tool fails its first call and only succeeds from the second call onward
# (like the real listener, which starts asynchronously while step 5's nix
# shell fetch is still running) -- proves the loop polls rather than
# reporting FAIL (or hanging) after a single attempt. Bound is overridden
# down to 6s (one 5s sleep) so this test does not need to wait anything
# close to the real 180s default.
NC_RETRY_COUNTER="$STUB_DIR/nc-retry-counter"
rm -f "$NC_RETRY_COUNTER"
reset_marker
set +e
retry_out="$(run_with_stubs "ssh docker nc_retry curl_ok" env DXE_QNAP_HOST=section27-host DXE_TEST_FAKE_TAILNET_ADDR="$FAKE_TAILNET_ADDR" DXE_TEST_NC_RETRY_COUNTER="$NC_RETRY_COUNTER" DXE_QNAP_LISTENER_WAIT_SECONDS=6 "$QNAP_SPIKE" --report "$SPIKE_REPORT" --summary "$SPIKE_SUMMARY" 2>&1)"
set -e
if [ -f "$NC_RETRY_COUNTER" ] && [ "$(cat "$NC_RETRY_COUNTER")" -ge 2 ]; then
    test_pass "step 7's direct-connect check is actually retried, not attempted only once"
else
    test_fail "step 7's direct-connect check is actually retried, not attempted only once"
fi
if printf '%s' "$retry_out" | stdin_matches -F -- "Step 7: PASS" \
    && printf '%s' "$retry_out" | stdin_matches -F -- "after 5s" \
    && printf '%s' "$retry_out" | stdin_matches -F -- "PONG confirmed"; then
    test_pass "step 7 passes once the retried connect succeeds, and reports how long it waited"
else
    test_fail "step 7 passes once the retried connect succeeds, and reports how long it waited"
fi

print_summary
exit_with_code
