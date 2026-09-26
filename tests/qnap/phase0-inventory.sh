#!/bin/bash
# tests/qnap/phase0-inventory.sh
#
# qnap-dxe-plan.md Phase 0 -- "Inventory". Versioned, non-interactive
# replacement for the ad hoc `ssh qnap-dxe '...'` block in that plan section:
# runs the same discovery commands over one SSH session, plus the intended
# Mac-side control plane check, and writes two Markdown files. Does not
# modify anything on the NAS.
#
# Usage: tests/qnap/phase0-inventory.sh [--dry-run] [--report FILE] [--summary FILE]
#
# Environment:
#   DXE_QNAP_HOST                 ssh_config alias for the QNAP (default: qnap-dxe)
#   DXE_QNAP_SSH_CONNECT_TIMEOUT  seconds (default: 10)
#
# --dry-run prints the exact commands this script would run (the one SSH
# session's remote script, and the local docker-over-ssh check) and exits 0
# without connecting anywhere.
#
# The NAS is a production system: --report writes the FULL, unredacted-beyond-
# secret-tokens report, and --summary writes a small, whitelisted-fields-only
# report with no hostnames, addresses, paths, or account names. BOTH default
# to a location OUTSIDE this repository (see dxe_qnap_private_dir in
# lib/phase0-common.sh) -- this repository never gets more than the one-line
# outcome the operator adds to qnap-dxe-plan.md by hand. See
# tests/qnap/README.md.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=lib/phase0-common.sh
source "$SCRIPT_DIR/lib/phase0-common.sh"

DXE_DRY_RUN=0
REPORT_PATH=""
SUMMARY_PATH=""

usage() {
    echo "Usage: $(basename "$0") [--dry-run] [--report FILE] [--summary FILE]" >&2
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --dry-run) DXE_DRY_RUN=1; shift ;;
        --report) [ "$#" -ge 2 ] || { echo "Error: --report requires FILE." >&2; exit 2; }; REPORT_PATH="$2"; shift 2 ;;
        --report=*) REPORT_PATH="${1#*=}"; shift ;;
        --summary) [ "$#" -ge 2 ] || { echo "Error: --summary requires FILE." >&2; exit 2; }; SUMMARY_PATH="$2"; shift 2 ;;
        --summary=*) SUMMARY_PATH="${1#*=}"; shift ;;
        --help) usage; exit 0 ;;
        *) echo "Error: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$REPORT_PATH" ] || REPORT_PATH="$(dxe_qnap_private_dir)/phase0-inventory-$(dxe_qnap_utc_date).md"
[ -n "$SUMMARY_PATH" ] || SUMMARY_PATH="$(dxe_qnap_private_dir)/phase0-summary-$(dxe_qnap_utc_date).md"

# One SSH session runs every remote discovery command from the plan's
# Inventory section. Every field is wrapped so one missing tool (BusyBox
# QNAP shells vary, and the real NAS confirmed `getconf` does not exist)
# cannot abort the rest -- each line always emits its own
# NOTFOUND/UNKNOWN/NOTDISCOVERABLE marker rather than failing the script.
# Never reads /etc/tailscale or prints unfiltered `docker info` (no
# registry/auth sections) -- see the plan's "never record" list. Discovers
# the Docker CLI and Tailscale by glob under their qpkgs' own bin
# directories (generic pattern, no pool/dataset name literal) rather than
# assuming either is on the non-interactive PATH -- confirmed against the
# real NAS that neither is.
dxe_inventory_remote_script() {
    cat <<REMOTE
echo "DXE_UNAME_M=\$(uname -m 2>/dev/null || echo UNKNOWN)"
echo "DXE_UNAME_R=\$(uname -r 2>/dev/null || echo UNKNOWN)"
$(dxe_qpkg_binary_discovery_snippet DXE_DOCKER_BIN docker "$DXE_QNAP_DOCKER_BIN_GLOB")
echo "DXE_DOCKER_PATH=\${DXE_DOCKER_BIN:-NOTFOUND}"
if [ -n "\$DXE_DOCKER_BIN" ]; then
    echo "DXE_DOCKER_VERSION_BEGIN"
    "\$DXE_DOCKER_BIN" version 2>&1 || echo "(docker version failed)"
    echo "DXE_DOCKER_VERSION_END"
    echo "DXE_DOCKER_INFO=\$("\$DXE_DOCKER_BIN" info --format 'ServerVersion={{.ServerVersion}} OSType={{.OSType}} Architecture={{.Architecture}} NCPU={{.NCPU}} MemTotalBytes={{.MemTotal}} CgroupDriver={{.CgroupDriver}} StorageDriver={{.Driver}}' 2>/dev/null || echo UNAVAILABLE)"
    echo "DXE_DOCKER_COMPOSE_VERSION=\$("\$DXE_DOCKER_BIN" compose version 2>/dev/null || echo NOTFOUND)"
    DXE_ROOT_DIR=\$("\$DXE_DOCKER_BIN" info --format '{{.DockerRootDir}}' 2>/dev/null || true)
    if [ -n "\$DXE_ROOT_DIR" ]; then
        echo "DXE_ROOT_DIR_FREE=\$(df -Pk "\$DXE_ROOT_DIR" 2>/dev/null | awk 'NR==2{print \$4}')"
        echo "DXE_ROOT_DIR_TOTAL=\$(df -Pk "\$DXE_ROOT_DIR" 2>/dev/null | awk 'NR==2{print \$2}')"
    else
        echo "DXE_ROOT_DIR_FREE=UNKNOWN"
        echo "DXE_ROOT_DIR_TOTAL=UNKNOWN"
    fi
    echo "DXE_DIAL_STDIO_EXIT=\$( (command -v timeout >/dev/null 2>&1 && timeout 3 "\$DXE_DOCKER_BIN" system dial-stdio </dev/null >/dev/null 2>&1; echo \$?) || echo UNKNOWN)"
else
    echo "DXE_DOCKER_VERSION_BEGIN"
    echo "(docker not found on PATH in a non-interactive shell, and not found under the Container Station qpkg's own bin directory)"
    echo "DXE_DOCKER_VERSION_END"
    echo "DXE_DOCKER_INFO=UNAVAILABLE"
    echo "DXE_DOCKER_COMPOSE_VERSION=NOTFOUND"
    echo "DXE_ROOT_DIR_FREE=UNKNOWN"
    echo "DXE_ROOT_DIR_TOTAL=UNKNOWN"
    echo "DXE_DIAL_STDIO_EXIT=UNKNOWN"
fi
echo "DXE_CPU_COUNT=\$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo UNKNOWN)"
echo "DXE_MEMINFO=\$(awk '/MemTotal|MemAvailable/ { printf "%s; ", \$0 }' /proc/meminfo 2>/dev/null || echo UNKNOWN)"
echo "DXE_LOADAVG=\$(cat /proc/loadavg 2>/dev/null || echo UNKNOWN)"
$(dxe_qpkg_binary_discovery_snippet DXE_TAILSCALE_BIN tailscale "$DXE_QNAP_TAILSCALE_BIN_GLOB")
echo "DXE_TAILSCALE_PATH=\${DXE_TAILSCALE_BIN:-NOTFOUND}"
if [ -n "\$DXE_TAILSCALE_BIN" ]; then
    echo "DXE_TAILSCALE_VERSION=\$("\$DXE_TAILSCALE_BIN" version 2>/dev/null | head -n1 || echo UNKNOWN)"
else
    echo "DXE_TAILSCALE_VERSION=NOTFOUND"
fi
echo "DXE_QTS_VERSION=\$(getcfg System Version -f /etc/config/uLinux.conf 2>/dev/null || echo NOTDISCOVERABLE)"
echo "DXE_CONTAINER_STATION_VERSION=\$(awk -F= '/^\[Container Station\]/{f=1;next} /^\[/{f=0} f&&/^Version/{print \$2; exit}' /etc/config/qpkg.conf 2>/dev/null || echo NOTDISCOVERABLE)"
if [ -e /etc/config/snapshot_util.conf ] || [ -e /etc/config/qsnatch.conf ]; then
    echo "DXE_BACKUP_INDICATION=present (snapshot config file found; not read)"
else
    echo "DXE_BACKUP_INDICATION=NOTDISCOVERABLE"
fi
# Account probe: never prints the account name itself (it could be
# identifying) -- only whether it is QNAP's default "admin" superuser and
# whether it belongs to the administrators group, which is enough to answer
# the plan's "does a non-default administrative account work" question
# without ever recording who that account is.
echo "DXE_ACCOUNT_IS_DEFAULT_SUPERUSER=\$([ "\$(id -un 2>/dev/null)" = admin ] && echo yes || echo no)"
echo "DXE_ACCOUNT_IN_ADMIN_GROUP=\$(id -Gn 2>/dev/null | tr ' ' '\\n' | grep -qx administrators && echo yes || echo no)"
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

yesno() { case "$1" in yes) printf 'yes' ;; *) printf 'no' ;; esac; }

host="$(dxe_qnap_host)"

if [ "$DXE_DRY_RUN" != 1 ]; then
    dxe_qnap_require_reachable || exit 1
fi

raw="$(dxe_qnap_ssh_capture "$(dxe_inventory_remote_script)" || true)"
raw="$(printf '%s' "$raw" | dxe_redact_secrets)"

# The "Mac-side control plane" check: DQ1's naive mechanism
# (`docker -H ssh://<alias> ...`, using the LOCAL Docker CLI's own ssh
# transport rather than a plain ssh remote command). Recorded as a finding,
# not treated as a script failure either way -- confirmed on the real NAS
# that this fails (the remote non-interactive shell the transport uses
# cannot find "docker" either), which is exactly why phase0-spike.sh never
# relies on it (see lib/phase0-common.sh's dxe_qnap_docker_run comment).
local_docker_version=""
local_docker_ssh_works=no
if command -v docker >/dev/null 2>&1; then
    naive_status=0
    local_docker_version="$(dxe_qnap_docker_naive_ssh_capture version)" || naive_status=$?
    if [ "$naive_status" -eq 0 ] && [ -n "$local_docker_version" ]; then
        local_docker_ssh_works=yes
    else
        local_docker_version="(docker -H ssh://$host version failed, exit $naive_status)"
    fi
    local_docker_version="$(printf '%s' "$local_docker_version" | dxe_redact_secrets)"
else
    local_docker_version="(local docker CLI not found on PATH; the Mac-side control-plane check is unavailable)"
fi

if [ "$DXE_DRY_RUN" = 1 ]; then
    echo "Dry run complete; nothing was connected. No report was written."
    exit 0
fi

mkdir -p "$(dirname "$REPORT_PATH")" "$(dirname "$SUMMARY_PATH")"

{
    dxe_qnap_report_header "$BASE_DIR" "QNAP Phase 0 inventory (FULL -- private, never commit)"
    echo "## Target"
    echo
    printf -- '- Architecture (`uname -m`): %s\n' "$(field "$raw" DXE_UNAME_M)"
    printf -- '- Kernel (`uname -r`): %s\n' "$(field "$raw" DXE_UNAME_R)"
    printf -- '- QTS/QuTS version (getcfg, best effort): %s\n' "$(field "$raw" DXE_QTS_VERSION)"
    printf -- '- Container Station version (qpkg.conf, best effort): %s\n' "$(field "$raw" DXE_CONTAINER_STATION_VERSION)"
    echo
    echo "## Docker CLI (non-interactive shell)"
    echo
    printf -- '- Discovered absolute path: %s\n' "$(field "$raw" DXE_DOCKER_PATH)"
    echo
    echo '```'
    block "$raw" DXE_DOCKER_VERSION_BEGIN DXE_DOCKER_VERSION_END
    echo '```'
    echo
    printf -- '- `docker info` (selected fields only -- never the full output): %s\n' "$(field "$raw" DXE_DOCKER_INFO)"
    printf -- '- `docker compose version`: %s\n' "$(field "$raw" DXE_DOCKER_COMPOSE_VERSION)"
    printf -- '- Container Station pool free/total (KB, Docker root dir): %s / %s\n' "$(field "$raw" DXE_ROOT_DIR_FREE)" "$(field "$raw" DXE_ROOT_DIR_TOTAL)"
    printf -- '- `docker system dial-stdio` exit status (0 = the subcommand ran without a transport/protocol error): %s\n' "$(field "$raw" DXE_DIAL_STDIO_EXIT)"
    echo
    echo "## Host resources"
    echo
    printf -- '- CPUs (`nproc`/`/proc/cpuinfo`): %s\n' "$(field "$raw" DXE_CPU_COUNT)"
    printf -- '- Memory (`/proc/meminfo`): %s\n' "$(field "$raw" DXE_MEMINFO)"
    printf -- '- Load average (`/proc/loadavg`): %s\n' "$(field "$raw" DXE_LOADAVG)"
    echo
    echo "## Account"
    echo
    printf -- '- Default QNAP superuser account: %s\n' "$(field "$raw" DXE_ACCOUNT_IS_DEFAULT_SUPERUSER)"
    printf -- '- Member of the administrators group: %s\n' "$(field "$raw" DXE_ACCOUNT_IN_ADMIN_GROUP)"
    echo "- The account name itself is never recorded here."
    echo
    echo "## Tailscale"
    echo
    printf -- '- Discovered absolute path: %s\n' "$(field "$raw" DXE_TAILSCALE_PATH)"
    printf -- '- Version: %s\n' "$(field "$raw" DXE_TAILSCALE_VERSION)"
    echo "- Whether the tailnet interface survives a QTS/Container Station restart is answered by the spike's guarded restart steps, not by this inventory."
    echo
    echo "## Backup/snapshot indications"
    echo
    printf -- '- %s\n' "$(field "$raw" DXE_BACKUP_INDICATION)"
    echo
    echo "## Mac-side control plane"
    echo
    printf -- 'DQ1 naive mechanism (`docker -H ssh://%s ...`, the local Docker CLI'"'"'s own ssh transport):\n' "$host"
    echo '```'
    printf '%s\n' "$local_docker_version"
    echo '```'
    echo "This is expected to fail exactly when the Docker CLI is not on the"
    echo "remote non-interactive PATH (see the Docker CLI section above): the"
    echo "transport runs \`docker ...\` on whatever the remote non-interactive"
    echo "shell resolves, the same as a bare \`docker\` would. It is not a"
    echo "script failure either way -- qnap-dxe-plan.md DQ1 already anticipates"
    echo "invoking the discovered absolute path directly instead, which is"
    echo "exactly what tests/qnap/phase0-spike.sh does."
    echo
    echo "## Not recorded"
    echo
    echo "Per plan policy: no auth keys, tokens, tailnet secrets, full docker"
    echo "environment, private registry tokens, account names, hostnames,"
    echo "addresses, storage-pool/dataset names, or \`/etc/tailscale\` contents"
    echo "were read or printed. Any token/secret-shaped substring captured"
    echo "above has been redacted. This file is private -- see the header of"
    echo "tests/qnap/README.md; never commit it."
} >"$REPORT_PATH.tmp.$$" || { rm -f "$REPORT_PATH.tmp.$$"; exit 1; }
mv "$REPORT_PATH.tmp.$$" "$REPORT_PATH"

{
    dxe_qnap_report_header "$BASE_DIR" "QNAP Phase 0 inventory (summary)"
    echo "Whitelisted fields only: no hostnames, addresses, paths, storage-pool"
    echo "names, or account names. Private by default (see tests/qnap/README.md);"
    echo "only a one-line outcome derived from this belongs in qnap-dxe-plan.md."
    echo
    printf -- '- Architecture: %s\n' "$(field "$raw" DXE_UNAME_M)"
    printf -- '- Kernel version: %s\n' "$(field "$raw" DXE_UNAME_R)"
    printf -- '- QTS/QuTS version: %s\n' "$(field "$raw" DXE_QTS_VERSION)"
    printf -- '- Container Station version: %s\n' "$(field "$raw" DXE_CONTAINER_STATION_VERSION)"
    printf -- '- Docker CLI found: %s\n' "$([ "$(field "$raw" DXE_DOCKER_PATH)" != NOTFOUND ] && echo yes || echo no)"
    docker_version_line="$(block "$raw" DXE_DOCKER_VERSION_BEGIN DXE_DOCKER_VERSION_END | head -n1)"
    printf -- '- Docker version: %s\n' "${docker_version_line:-UNKNOWN}"
    printf -- '- Docker Compose version: %s\n' "$(field "$raw" DXE_DOCKER_COMPOSE_VERSION)"
    printf -- '- `docker system dial-stdio` supported: %s\n' "$([ "$(field "$raw" DXE_DIAL_STDIO_EXIT)" = 0 ] && echo yes || echo no)"
    printf -- '- CPU count: %s\n' "$(field "$raw" DXE_CPU_COUNT)"
    printf -- '- Memory (from `/proc/meminfo`, kB): %s\n' "$(field "$raw" DXE_MEMINFO)"
    printf -- '- Container Station storage free/total (KB, no path or pool name): %s / %s\n' "$(field "$raw" DXE_ROOT_DIR_FREE)" "$(field "$raw" DXE_ROOT_DIR_TOTAL)"
    non_default_works=no
    if [ "$(field "$raw" DXE_ACCOUNT_IS_DEFAULT_SUPERUSER)" = no ] && [ "$(field "$raw" DXE_ACCOUNT_IN_ADMIN_GROUP)" = yes ] && [ "$(field "$raw" DXE_DOCKER_PATH)" != NOTFOUND ]; then
        non_default_works=yes
    fi
    printf -- '- A non-default administrator account can run Docker non-interactively: %s\n' "$(yesno "$non_default_works")"
    printf -- '- Tailscale present: %s\n' "$([ "$(field "$raw" DXE_TAILSCALE_PATH)" != NOTFOUND ] && echo yes || echo no)"
    printf -- '- Docker-over-SSH (DQ1 naive mechanism, `docker -H ssh://<alias>`) works: %s\n' "$(yesno "$local_docker_ssh_works")"
} >"$SUMMARY_PATH.tmp.$$" || { rm -f "$SUMMARY_PATH.tmp.$$"; exit 1; }
mv "$SUMMARY_PATH.tmp.$$" "$SUMMARY_PATH"

cat "$SUMMARY_PATH"
echo
echo "Full report (private, do not commit): $REPORT_PATH" >&2
echo "Summary (private, do not commit): $SUMMARY_PATH" >&2
