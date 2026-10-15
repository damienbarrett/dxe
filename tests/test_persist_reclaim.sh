#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP5.2 acceptance: dx-reclaim reporting (plans/do spec R29).
#
# Interface contract (pinned by this file; the implementation must match):
#
#   bin/dx-reclaim, run as an entry point against the docker-ssh adapter
#   (recording fake docker + the NAS fake), prints a "Before" and an "After"
#   usage report. In HOST-PATH mode (DX_PERSIST_STORAGE=host-path):
#     - the report is the same "Volume usage:" block as today, with the nix
#       volume line unchanged ("  <DX_NIX_VOLUME padded to 14> <size>"), and
#       then, as its last line, ONE persist-directory line:
#           "  <DIR> <KIB>K"
#       i.e. two spaces, the directory, ONE space, then the KiB count that
#       dx_runtime_host_dir_usage printed (the leading integer of
#       `du -sk -- DIR`) followed by the letter K. DIR is
#       "$DX_PERSIST_HOST_ROOT/dxe/$DX_CONTAINER_NAME/persist" exactly as
#       dx_persist_configured_source prints it. The size comes from
#       dx_runtime_host_dir_usage DIR (one ssh call per report, so two per
#       run); it is never "unknown" when the call succeeds.
#     - If dx_runtime_host_dir_usage fails (e.g. the directory is missing),
#       the line is "  <DIR> unknown" and dx-reclaim carries on (exit 0).
#     - The persist VOLUME is not queried at all: no `docker system df`
#       call mentions DX_PERSIST_VOLUME, and no persist line is named after it.
#     - The trim step is skipped (docker-ssh has no host_filesystem_reclamation)
#       with a message that starts "Skipping filesystem trim", contains the
#       words "host directory", and does NOT contain "Docker volume". fstrim
#       never runs.
#   In VOLUME mode (the default) stdout+stderr and the recorded docker and
#   ssh transcripts are byte-identical to the current tree's: fixtures
#   tests/fixtures/persist-reclaim-volume.{out,docker,ssh} were captured from
#   the tree before this WP and are compared byte for byte.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/persist-fixtures.sh
source "$SCRIPT_DIR/lib/persist-fixtures.sh"

test_section "WP5.2: dx-reclaim reporting"

SCRATCH="$(persist_fixture_root_create)" || exit 1
trap 'persist_fixture_cleanup "$SCRATCH"' EXIT
case "$SCRATCH" in
    /*/dxe-persist-share.*) : ;;
    *) echo "unexpected scratch dir [$SCRATCH]" >&2; exit 1 ;;
esac

GUEST="dx-rc"
NIXV="dxe-rc-nix"
PERSISTV="dxe-rc-persist"
FIXDIR="$SCRIPT_DIR/fixtures"

# A share root with a persist directory holding 300000 bytes.
ROOT="$(persist_fixture_root_create "$SCRATCH")" || exit 1
ROOT="$(cd -P -- "$ROOT" && pwd -P)"
PDIR="$ROOT/dxe/$GUEST/persist"
mkdir -p "$PDIR"
perl -e 'print "x" x 300000' >"$PDIR/blob"
TOOLS="$(persist_fixture_nas_create "$ROOT" "$SCRATCH")" || exit 1
fake_tool_write "$TOOLS" uname 'case "$1" in -m) echo x86_64 ;; esac'
fake_tool_write "$TOOLS" docker '
if [ -n "${DXE_RC_DOCKER_LOG:-}" ]; then printf "%s\n" "$*" >> "$DXE_RC_DOCKER_LOG"; fi
case "$1 $2" in
    "version --format") echo "27.3.1"; exit 0 ;;
    "info --format") echo "abc123def|qnap-fake|x86_64|linux"; exit 0 ;;
    "container inspect") echo true; exit 0 ;;
    "system df")
        shift 2
        case "$*" in
            *dxe-rc-nix*"{{.Size}}"*) echo 4.835MB ;;
            *dxe-rc-persist*"{{.Size}}"*) echo 7.5GB ;;
        esac
        exit 0
        ;;
esac
case "$1" in
    exec)
        shift
        case "$*" in
            *fstrim*) echo "fstrim must never run under docker-ssh" >&2; exit 99 ;;
            *) exit 0 ;;
        esac
        ;;
esac
echo "UNMATCHED: $*" >&2; exit 99'

HOME_DIR="$SCRATCH/home"
mkdir -p "$HOME_DIR"
OUT="$SCRATCH/out"
DLOG="$SCRATCH/docker.log"
SLOG="$SCRATCH/ssh.log"
RC=0

# reclaim MODE [ROOT]: run bin/dx-reclaim; fills $OUT, $DLOG, $SLOG, $RC.
reclaim() {
    local mode="$1" root="${2:-$ROOT}"
    : >"$DLOG"
    : >"$SLOG"
    (
        export HOME="$HOME_DIR" XDG_STATE_HOME="$HOME_DIR/state"
        export DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$PERSIST_FIXTURE_NAS_HOST"
        export DX_GUEST_SYSTEM=x86_64-linux DX_NIX_STORAGE_MODE=direct-volume
        export DX_CONTAINER_NAME="$GUEST" DX_NIX_VOLUME="$NIXV" DX_PERSIST_VOLUME="$PERSISTV" DX_NIX_MOUNT=/nix
        export DXE_RC_DOCKER_LOG="$DLOG" DXE_FAKE_SSH_ARGV_LOG="$SLOG"
        if [ "$mode" = host-path ]; then
            export DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT="$root"
        fi
        PATH="$TOOLS:/usr/bin:/bin"
        export PATH
        "$BASE_DIR/bin/dx-reclaim" </dev/null
    ) >"$OUT" 2>&1
    RC=$?
    # The fake tool directory is a per-run temp path; normalise it.
    sed "s|$TOOLS|<TOOLS>|g" "$SLOG" >"$SLOG.n" && mv "$SLOG.n" "$SLOG"
}

count_fixed() { # FILE NEEDLE -> number of lines equal to NEEDLE
    grep -Fxc -- "$2" "$1" 2>/dev/null || true
}

# --- host-path mode -----------------------------------------------------
reclaim host-path
KIB="$(du -sk -- "$PDIR" | awk '{print $1}')"
LINE="  $PDIR ${KIB}K"

if [ "$RC" -eq 0 ]; then test_pass "host-path: dx-reclaim exits 0"; else test_fail "host-path: dx-reclaim exits 0 (rc=$RC: $(cat "$OUT"))"; fi
if [ "$KIB" -ge 290 ] 2>/dev/null; then test_pass "host-path: fixture directory is non-trivial (${KIB}K)"; else test_fail "host-path: fixture directory is non-trivial (${KIB}K)"; fi
if [ "$(count_fixed "$OUT" "$LINE")" = 2 ]; then
    test_pass "host-path: persist directory usage line appears in both reports"
else
    test_fail "host-path: persist directory usage line appears in both reports (want [$LINE]; got: $(cat "$OUT"))"
fi
NIXLINE="$(printf '  %-14s %s' "$NIXV" 4.835MB)"
if [ "$(count_fixed "$OUT" "$NIXLINE")" = 2 ]; then
    test_pass "host-path: nix volume usage line unchanged in both reports"
else
    test_fail "host-path: nix volume usage line unchanged in both reports (want [$NIXLINE])"
fi
# Order inside each report: heading, nix line, persist line.
ORDER="$(grep -Fx -e 'Volume usage:' -e "$NIXLINE" -e "$LINE" "$OUT" | tr '\n' '|')"
if [ "$ORDER" = "Volume usage:|$NIXLINE|$LINE|Volume usage:|$NIXLINE|$LINE|" ]; then
    test_pass "host-path: each report is heading, nix line, persist directory line"
else
    test_fail "host-path: each report is heading, nix line, persist directory line (got [$ORDER])"
fi
if grep -Fq unknown "$OUT"; then test_fail "host-path: persist usage is never 'unknown'"; else test_pass "host-path: persist usage is never 'unknown'"; fi
if grep -Fq "$PERSISTV" "$OUT"; then test_fail "host-path: the persist volume name is not reported"; else test_pass "host-path: the persist volume name is not reported"; fi
if grep -Fq "$PERSISTV" "$DLOG"; then test_fail "host-path: the persist volume is not queried with docker"; else test_pass "host-path: the persist volume is not queried with docker"; fi
if grep -Fq "$NIXV" "$DLOG"; then test_pass "host-path: the nix volume is still queried"; else test_fail "host-path: the nix volume is still queried"; fi
if grep -Fq 'Skipping filesystem trim' "$OUT"; then test_pass "host-path: trim is skipped"; else test_fail "host-path: trim is skipped"; fi
if grep -F 'Skipping filesystem trim' "$OUT" | grep -Fq 'host directory'; then
    test_pass "host-path: skip message says 'host directory'"
else
    test_fail "host-path: skip message says 'host directory'"
fi
if grep -Fq 'Docker volume' "$OUT"; then test_fail "host-path: output never calls /persist a 'Docker volume'"; else test_pass "host-path: output never calls /persist a 'Docker volume'"; fi
if grep -Fq 'Trimming guest filesystems' "$OUT"; then test_fail "host-path: no trim step runs"; else test_pass "host-path: no trim step runs"; fi
if grep -Fq fstrim "$DLOG" "$OUT"; then test_fail "host-path: fstrim never reached"; else test_pass "host-path: fstrim never reached"; fi
if grep -Fq 'nix-collect-garbage' "$DLOG"; then test_pass "host-path: Nix garbage collection still runs"; else test_fail "host-path: Nix garbage collection still runs"; fi
if grep -Fxq 'Reclaim complete.' "$OUT"; then test_pass "host-path: ends with 'Reclaim complete.'"; else test_fail "host-path: ends with 'Reclaim complete.'"; fi
# Exactly the two usage reads, each a du -sk of the derived directory, on the NAS.
DU_CALLS="$(grep -F -e "du\\ -sk" "$SLOG" | grep -Fc -e " sh $PDIR")"
if [ "$DU_CALLS" = 2 ]; then test_pass "host-path: one du -sk of the derived directory per report"; else test_fail "host-path: one du -sk of the derived directory per report (got $DU_CALLS)"; fi

# The number tracks the directory: grow it, run again.
perl -e 'print "y" x 900000' >"$PDIR/blob2"
reclaim host-path
KIB2="$(du -sk -- "$PDIR" | awk '{print $1}')"
if [ "$KIB2" != "$KIB" ] && [ "$(count_fixed "$OUT" "  $PDIR ${KIB2}K")" = 2 ]; then
    test_pass "host-path: the reported size follows the directory (${KIB}K -> ${KIB2}K)"
else
    test_fail "host-path: the reported size follows the directory (${KIB}K -> ${KIB2}K): $(cat "$OUT")"
fi

# A missing directory: reported as unknown, and the run still completes.
EMPTY_ROOT="$(persist_fixture_root_create "$SCRATCH")" || exit 1
EMPTY_ROOT="$(cd -P -- "$EMPTY_ROOT" && pwd -P)"
reclaim host-path "$EMPTY_ROOT"
MLINE="  $EMPTY_ROOT/dxe/$GUEST/persist unknown"
if [ "$RC" -eq 0 ] && [ "$(count_fixed "$OUT" "$MLINE")" = 2 ]; then
    test_pass "host-path: a failing usage read prints 'unknown' for the directory and carries on"
else
    test_fail "host-path: a failing usage read prints 'unknown' for the directory and carries on (rc=$RC: $(cat "$OUT"))"
fi

# --- volume mode: byte-identical to the tree before this WP ---------------
reclaim volume
if [ "$RC" -eq 0 ]; then test_pass "volume mode: dx-reclaim exits 0"; else test_fail "volume mode: dx-reclaim exits 0 (rc=$RC)"; fi
if [ -n "${DXE_RECLAIM_CAPTURE:-}" ]; then
    cp "$OUT" "$DXE_RECLAIM_CAPTURE/persist-reclaim-volume.out"
    cp "$DLOG" "$DXE_RECLAIM_CAPTURE/persist-reclaim-volume.docker"
    cp "$SLOG" "$DXE_RECLAIM_CAPTURE/persist-reclaim-volume.ssh"
fi
for ext in out docker ssh; do
    case "$ext" in out) got="$OUT" ;; docker) got="$DLOG" ;; ssh) got="$SLOG" ;; esac
    if cmp -s "$FIXDIR/persist-reclaim-volume.$ext" "$got"; then
        test_pass "volume mode: $ext is byte-identical to the pre-WP5.2 capture"
    else
        test_fail "volume mode: $ext is byte-identical to the pre-WP5.2 capture"
    fi
done
if grep -Fq 'Docker volume' "$OUT"; then test_pass "volume mode: skip message still says 'Docker volume'"; else test_fail "volume mode: skip message still says 'Docker volume'"; fi
if grep -Fxq "$(printf "  %-14s %s" "$PERSISTV" 7.5GB)" "$OUT"; then test_pass "volume mode: persist volume usage line still reported"; else test_fail "volume mode: persist volume usage line still reported"; fi
if grep -Fq 'du\ -sk' "$SLOG"; then test_fail "volume mode: no directory usage read"; else test_pass "volume mode: no directory usage read"; fi

finish
