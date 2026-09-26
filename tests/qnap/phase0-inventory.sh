#!/bin/bash
# tests/qnap/phase0-inventory.sh
#
# qnap-dxe-plan.md Phase 0 -- "Inventory". Versioned, non-interactive
# replacement for the ad hoc `ssh qnap-dxe '...'` block in that plan section:
# runs the same discovery commands over one SSH session, plus the intended
# Mac-side control plane check (`docker -H ssh://<alias> version`), and
# writes a sanitised Markdown report. Does not modify anything on the NAS.
#
# Usage: tests/qnap/phase0-inventory.sh [--dry-run] [--report FILE]
#
# Environment:
#   DXE_QNAP_HOST                 ssh_config alias for the QNAP (default: qnap-dxe)
#   DXE_QNAP_SSH_CONNECT_TIMEOUT  seconds (default: 10)
#
# --dry-run prints the exact commands this script would run (the one SSH
# session's remote script, and the local docker-over-ssh check) and exits 0
# without connecting anywhere.
#
# See tests/qnap/README.md for how to prepare access and read the report.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/phase0-common.sh
source "$SCRIPT_DIR/lib/phase0-common.sh"

DXE_DRY_RUN=0
REPORT_PATH=""

usage() {
    echo "Usage: $(basename "$0") [--dry-run] [--report FILE]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DXE_DRY_RUN=1; shift ;;
        --report) [ "$#" -ge 2 ] || { echo "Error: --report requires FILE." >&2; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
        --report=*) REPORT_PATH="${1#*=}"; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

if [ -z "$REPORT_PATH" ]; then
    REPORT_PATH="$BASE_DIR/docs/evidence/qnap/phase0-inventory-$(dxe_qnap_utc_date).md"
fi

# One SSH session runs every remote discovery command from the plan's
# Inventory section. Every field is wrapped so one missing tool (busybox
# QNAP shells vary) cannot abort the rest -- each line always emits its own
# NOTFOUND/UNKNOWN/NOTDISCOVERABLE marker rather than failing the script.
# Never reads /etc/tailscale or prints unfiltered `docker info` (no
# registry/auth sections) -- see the plan's "never record" list.
dxe_inventory_remote_script() {
    cat <<'REMOTE'
echo "DXE_UNAME_M=$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "DXE_UNAME_R=$(uname -r 2>/dev/null || echo UNKNOWN)"
echo "DXE_DOCKER_PATH=$(command -v docker 2>/dev/null || echo NOTFOUND)"
if command -v docker >/dev/null 2>&1; then
    echo "DXE_DOCKER_VERSION_BEGIN"
    docker version 2>&1 || echo "(docker version failed)"
    echo "DXE_DOCKER_VERSION_END"
    echo "DXE_DOCKER_INFO=$(docker info --format 'ServerVersion={{.ServerVersion}} OSType={{.OSType}} Architecture={{.Architecture}} NCPU={{.NCPU}} MemTotalBytes={{.MemTotal}} CgroupDriver={{.CgroupDriver}} StorageDriver={{.Driver}} DockerRootDir={{.DockerRootDir}}' 2>/dev/null || echo UNAVAILABLE)"
    echo "DXE_DOCKER_COMPOSE_VERSION=$(docker compose version 2>/dev/null || docker-compose version 2>/dev/null || echo NOTFOUND)"
    DXE_ROOT_DIR=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    if [ -n "$DXE_ROOT_DIR" ]; then
        echo "DXE_ROOT_DIR_FREE=$(df -Pk "$DXE_ROOT_DIR" 2>/dev/null | awk 'NR==2{print $4"K free of "$2"K total"}')"
    else
        echo "DXE_ROOT_DIR_FREE=UNKNOWN"
    fi
    echo "DXE_DIAL_STDIO_EXIT=$( (command -v timeout >/dev/null 2>&1 && timeout 3 docker system dial-stdio </dev/null >/dev/null 2>&1; echo $?) || echo UNKNOWN)"
else
    echo "DXE_DOCKER_VERSION_BEGIN"
    echo "(docker not found on PATH in a non-interactive shell)"
    echo "DXE_DOCKER_VERSION_END"
    echo "DXE_DOCKER_INFO=UNAVAILABLE"
    echo "DXE_DOCKER_COMPOSE_VERSION=NOTFOUND"
    echo "DXE_ROOT_DIR_FREE=UNKNOWN"
    echo "DXE_DIAL_STDIO_EXIT=UNKNOWN"
fi
echo "DXE_CPU_COUNT=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo UNKNOWN)"
echo "DXE_MEMINFO=$(awk '/MemTotal|MemAvailable/ { printf "%s; ", $0 }' /proc/meminfo 2>/dev/null || echo UNKNOWN)"
echo "DXE_LOADAVG=$(cat /proc/loadavg 2>/dev/null || echo UNKNOWN)"
echo "DXE_TAILSCALE_PATH=$(command -v tailscale 2>/dev/null || echo NOTFOUND)"
if command -v tailscale >/dev/null 2>&1; then
    echo "DXE_TAILSCALE_VERSION=$(tailscale version 2>/dev/null | head -n1 || echo UNKNOWN)"
else
    echo "DXE_TAILSCALE_VERSION=NOTFOUND"
fi
echo "DXE_QTS_VERSION=$(getcfg System Version -f /etc/config/uLinux.conf 2>/dev/null || echo NOTDISCOVERABLE)"
echo "DXE_CONTAINER_STATION_VERSION=$(awk -F= '/^\[Container Station\]/{f=1;next} /^\[/{f=0} f&&/^Version/{print $2; exit}' /etc/config/qpkg.conf 2>/dev/null || echo NOTDISCOVERABLE)"
if [ -e /etc/config/snapshot_util.conf ] || [ -e /etc/config/qsnatch.conf ]; then
    echo "DXE_BACKUP_INDICATION=present (snapshot config file found; not read)"
else
    echo "DXE_BACKUP_INDICATION=NOTDISCOVERABLE"
fi
REMOTE
}

field() {
    # $1: report text, $2: DXE_ tag. Extracts the (first) value after "TAG=".
    printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n1
}

block() {
    # $1: report text, $2: BEGIN tag, $3: END tag. Extracts lines strictly
    # between the two marker lines.
    printf '%s\n' "$1" | sed -n "/^$2\$/,/^$3\$/p" | sed "1d;\$d"
}

host="$(dxe_qnap_host)"

if [ "$DXE_DRY_RUN" != 1 ]; then
    dxe_qnap_require_reachable || exit 1
fi

raw="$(dxe_qnap_ssh_capture "$(dxe_inventory_remote_script)" || true)"
raw="$(printf '%s' "$raw" | dxe_redact_secrets)"

local_docker_version=""
if command -v docker >/dev/null 2>&1; then
    local_docker_version="$(dxe_qnap_docker_capture version || echo "(docker -H ssh://$host version failed)")"
    local_docker_version="$(printf '%s' "$local_docker_version" | dxe_redact_secrets)"
else
    local_docker_version="(local docker CLI not found on PATH; the Mac-side control-plane check is unavailable)"
fi

if [ "$DXE_DRY_RUN" = 1 ]; then
    echo "Dry run complete; nothing was connected. No report was written."
    exit 0
fi

mkdir -p "$(dirname "$REPORT_PATH")"

{
    dxe_qnap_report_header "$BASE_DIR" "QNAP Phase 0 inventory"
    echo "## Target"
    echo
    printf -- '- Architecture (`uname -m`): %s\n' "$(field "$raw" DXE_UNAME_M)"
    printf -- '- Kernel (`uname -r`): %s\n' "$(field "$raw" DXE_UNAME_R)"
    printf -- '- QTS/QuTS version (getcfg, best effort): %s\n' "$(field "$raw" DXE_QTS_VERSION)"
    printf -- '- Container Station version (qpkg.conf, best effort): %s\n' "$(field "$raw" DXE_CONTAINER_STATION_VERSION)"
    echo
    echo "## Docker CLI (non-interactive shell)"
    echo
    printf -- '- `command -v docker`: %s\n' "$(field "$raw" DXE_DOCKER_PATH)"
    echo
    echo '```'
    block "$raw" DXE_DOCKER_VERSION_BEGIN DXE_DOCKER_VERSION_END
    echo '```'
    echo
    printf -- '- `docker info` (selected fields only -- never the full output): %s\n' "$(field "$raw" DXE_DOCKER_INFO)"
    printf -- '- `docker compose version`: %s\n' "$(field "$raw" DXE_DOCKER_COMPOSE_VERSION)"
    printf -- '- Container Station pool free space (Docker root dir): %s\n' "$(field "$raw" DXE_ROOT_DIR_FREE)"
    printf -- '- `docker system dial-stdio` exit status (0 = the subcommand ran without a transport/protocol error): %s\n' "$(field "$raw" DXE_DIAL_STDIO_EXIT)"
    echo
    echo "## Host resources"
    echo
    printf -- '- CPUs (`getconf _NPROCESSORS_ONLN`): %s\n' "$(field "$raw" DXE_CPU_COUNT)"
    printf -- '- Memory (`/proc/meminfo`): %s\n' "$(field "$raw" DXE_MEMINFO)"
    printf -- '- Load average (`/proc/loadavg`): %s\n' "$(field "$raw" DXE_LOADAVG)"
    echo
    echo "## Tailscale"
    echo
    printf -- '- `command -v tailscale`: %s\n' "$(field "$raw" DXE_TAILSCALE_PATH)"
    printf -- '- Version: %s\n' "$(field "$raw" DXE_TAILSCALE_VERSION)"
    echo "- Whether the tailnet interface survives a QTS/Container Station restart is answered by the spike's guarded restart steps, not by this inventory."
    echo
    echo "## Backup/snapshot indications"
    echo
    printf -- '- %s\n' "$(field "$raw" DXE_BACKUP_INDICATION)"
    echo
    echo "## Mac-side control plane"
    echo
    printf -- '`docker -H ssh://%s version`:\n' "$host"
    echo '```'
    printf '%s\n' "$local_docker_version"
    echo '```'
    echo
    echo "## Not recorded"
    echo
    echo "Per plan policy: no auth keys, tokens, tailnet secrets, full docker"
    echo "environment, private registry tokens, or \`/etc/tailscale\` contents"
    echo "were read or printed. Any token/secret-shaped substring captured"
    echo "above has been redacted."
} >"$REPORT_PATH.tmp.$$" || { rm -f "$REPORT_PATH.tmp.$$"; exit 1; }

mv "$REPORT_PATH.tmp.$$" "$REPORT_PATH"
cat "$REPORT_PATH"
echo
echo "Report written to $REPORT_PATH" >&2
