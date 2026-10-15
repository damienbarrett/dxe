#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP9.1 (spec R1-R3, section 8, W6, section 11): the final documentation pass
# for /persist host access. Section-10 style: fixed-string, case-insensitive
# checks scoped to one named section of each document, plus two small
# behaviour/comment checks. Nothing is executed except `bin/dx-recreate` with
# fail-closed fakes (it stops at its first runtime check; stdout is its banner).
#
# Interface contract (a "paragraph" is a run of lines with no blank line; a
# check "PARA a @@ b" means ONE paragraph of the section holds every listed
# string, case-insensitive, fixed):
#
#  docs/lifecycle.md  -- section "### /persist storage modes" (to the next
#    heading of level 3 or higher):
#      PARA DX_PERSIST_STORAGE=volume @@ named volume @@ Apple
#      PARA DX_PERSIST_STORAGE=host-path @@ <qnap-share> @@ marker @@ ready
#      PARA dx-destroy-volumes @@ dx-factory-reset @@ host-path @@ keep
#      PARA source-volume @@ persist volume @@ directory
#      PARA dx-status @@ kept @@ removal         (kept things are removed by hand)
#      PARA dx-reclaim @@ du
#      the section holds "fixed at creation" and "dx-recreate".
#    Elsewhere in the file: principle 6 ("6. **Persistent volumes ...", to
#    principle 7) mentions host-path; the table row starting
#    "| [`bin/dx-recreate`]" mentions host-path.
#
#  docs/troubleshooting.md -- section "### /persist host directory refusals"
#    (to the next heading of level 3 or higher): one paragraph per refusal
#    holding the Error fragment AND its fix (the fragment lists are below), and
#      PARA self-check @@ stops          (the guest's own check)
#      PARA Verified host-path           (what a healthy start prints)
#    Section "### A guest tool does not notice a change made from the host":
#      PARA watcher @@ miss @@ refresh @@ restart
#
#  docs/guest.md -- section "## Changing /persist from the host" (to the next
#    level-2 heading):
#      PARA project files @@ inbox/
#      PARA .claude @@ .codex @@ .gemini @@ herdr @@ tmux @@ etc/ssh @@ git
#      PARA migration @@ rollback @@ nothing under
#      PARA nothing enforces
#      PARA watcher @@ troubleshooting.md
#      PARA Public @@ SMB @@ read and modify @@ etc/ssh @@ credentials @@ accepted
#      PARA .DS_Store @@ ._* @@ no remedy is needed   (Q-6: Finder left none)
#
#  qnap-dxe-plan.md -- the DQ4 section ("### DQ4 ...", to the next ### heading)
#    holds a paragraph starting "**Status" with host-path, DX_PERSIST_STORAGE
#    and docs/lifecycle.md; no "/share/" anywhere in the file.
#
#  docs/qnap-runbook.md -- (already pinned in section 11.2 by WP6.6) still says
#    Public, SMB, "read and modify".
#  docs/configuration.md -- table rows for DX_PERSIST_STORAGE,
#    DX_PERSIST_HOST_ROOT, DX_PERSIST_HOST_MOUNT_SENTINEL; DX_PERSIST_FRESH_START
#    described.
#
#  bin/dx-recreate -- first stdout line starts "Recreating DX environment (",
#    holds "preserves /nix" and "host directory", and does NOT hold
#    "preserves /nix and /persist)" (that is true only for a volume); its header
#    comment lines mention "host directory".
#
#  bin/lib/dx-runtime.sh -- no comment says rsync runs "from $DX_IMAGE"; the
#    rsync comment says it runs from the guest's nix volume.
#
#  tests/test_persist_host_dir_live.sh -- the manual-removal hint takes the
#    docker binary from the adapter's own discovery (dx_runtime_docker_require_bin,
#    falling back to the word docker), never from a literal path: the file holds
#    no "container-station" and no "/share/".

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=tests/lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

test_section "WP9.1: final /persist host-access documentation"

dxe_test_mktemp_dir TMP_ROOT "${TMPDIR:-/tmp}/dxe-final-docs.XXXXXX"
trap 'rmdir "$TMP_ROOT" 2>/dev/null || :' EXIT
SEC_FILE="$TMP_ROOT/section"
cleanup_section() { [ ! -f "$SEC_FILE" ] || rm -f "$SEC_FILE"; }
trap 'cleanup_section; rmdir "$TMP_ROOT" 2>/dev/null || :' EXIT

# section FILE HEADING LEVEL: the heading line up to (not including) the next
# heading of level LEVEL or shallower.
section() {
    awk -v h="$2" -v lvl="$3" '
        function level(s,   n) { n = 0; while (substr(s, n + 1, 1) == "#") n++; return n }
        $0 == h || index($0, h) == 1 { on = 1; print; next }
        on && /^#/ && level($0) <= lvl { exit }
        on { print }
    ' "$1"
}

# para_has SECTION "a @@ b @@ c": one paragraph holds all the strings.
para_has() {
    printf '%s\n' "$1" > "$SEC_FILE"
    awk -v needles="$2" '
        BEGIN { RS = ""; n = split(tolower(needles), want, " @@ ") }
        {
            p = tolower($0); ok = 1
            for (i = 1; i <= n; i++) if (index(p, want[i]) == 0) { ok = 0; break }
            if (ok) { found = 1; exit }
        }
        END { exit found ? 0 : 1 }
    ' "$SEC_FILE"
}
check_para() { # SECTION NEEDLES LABEL
    if para_has "$1" "$2"; then test_pass "$3"; else test_fail "$3 (no single paragraph holds: $2)"; fi
}
check_has() { # TEXT NEEDLE LABEL
    if grep -Fiq -- "$2" <<<"$1"; then test_pass "$3"; else test_fail "$3 (missing '$2')"; fi
}
need_section() { # TEXT LABEL
    if [ -n "$1" ]; then test_pass "$2"; else test_fail "$2"; fi
}

# --- docs/lifecycle.md ---
LC="$BASE_DIR/docs/lifecycle.md"
S="$(section "$LC" "### /persist storage modes" 3)"
need_section "$S" "lifecycle.md has '### /persist storage modes'"
check_para "$S" "DX_PERSIST_STORAGE=volume @@ named volume @@ Apple" "lifecycle: volume mode (the Apple mode)"
check_para "$S" "DX_PERSIST_STORAGE=host-path @@ <qnap-share> @@ marker @@ ready" "lifecycle: host-path mode and its marker"
check_para "$S" "dx-destroy-volumes @@ dx-factory-reset @@ host-path @@ keep" "lifecycle: destroy and reset keep the directory"
check_para "$S" "source-volume @@ persist volume @@ directory" "lifecycle: the retained persist volumes"
check_para "$S" "dx-status @@ kept @@ removal" "lifecycle: kept things are listed and removed by hand"
check_para "$S" "dx-reclaim @@ du" "lifecycle: dx-reclaim reports the directory's size"
check_has "$S" "fixed at creation" "lifecycle: mounts are fixed at creation"
check_has "$S" "dx-recreate" "lifecycle: dx-recreate applies a mode change"
P6="$(awk '/^6\. \*\*Persistent volumes/ { on = 1; print; next } on && /^7\. / { exit } on { print }' "$LC")"
need_section "$P6" "lifecycle: principle 6 found"
check_has "$P6" "host-path" "lifecycle: principle 6 qualifies itself for host-path"
ROW="$(grep -F '| [`bin/dx-recreate`]' "$LC" || true)"
check_has "$ROW" "host-path" "lifecycle: the dx-recreate table row is accurate for host-path"

# --- docs/troubleshooting.md ---
TS_DOC="$BASE_DIR/docs/troubleshooting.md"
S="$(section "$TS_DOC" "### /persist host directory refusals" 3)"
need_section "$S" "troubleshooting.md has '### /persist host directory refusals'"
check_para "$S" "is missing, but @@ NAS snapshot @@ dx-persist-migrate" "refusal: missing directory"
check_para "$S" "is a symlink @@ real directory" "refusal: symlink"
check_para "$S" "belongs to another guest @@ DX_CONTAINER_NAME" "refusal: another guest's directory"
check_para "$S" "is marked copying @@ dx-persist-migrate" "refusal: copying"
check_para "$S" "is marked retired @@ DX_PERSIST_STORAGE=volume" "refusal: retired"
check_para "$S" "is not empty and has no @@ .dxe-persist-dir @@ dx-persist-migrate @@ move it aside" "refusal: unmarked, not empty"
check_para "$S" "is empty and unmarked @@ DX_PERSIST_FRESH_START @@ dx-create-volumes" "refusal: empty with earlier storage"
check_para "$S" "does not look mounted @@ DX_PERSIST_HOST_MOUNT_SENTINEL @@ mount or unlock" "refusal: share not mounted"
check_para "$S" "cannot tell whether the share root @@ DX_PERSIST_HOST_MOUNT_SENTINEL" "refusal: mount state unknown"
check_para "$S" "cannot tell whether the persist volume @@ docker volume inspect @@ Nothing was changed" "refusal: volume state unknown"
check_para "$S" "not a valid /persist marker @@ move the directory aside" "refusal: invalid marker"
check_para "$S" "not a usable directory @@ DX_PERSIST_HOST_ROOT" "refusal: unusable share root"
check_para "$S" "is not a mount point @@ dx-recreate" "guest self-check: not a mount point"
check_para "$S" "is not a prepared directory @@ share" "guest self-check: marker missing"
check_para "$S" "is malformed @@ inspect" "guest self-check: marker malformed"
check_para "$S" ", not ready @@ volume mode" "guest self-check: marker not ready"
check_para "$S" "self-check @@ stops" "the guest's own check stops the guest"
check_para "$S" "Verified host-path" "what a healthy start prints"
S="$(section "$TS_DOC" "### A guest tool does not notice a change made from the host" 3)"
need_section "$S" "troubleshooting.md has the file-watcher entry"
check_para "$S" "watcher @@ miss @@ refresh @@ restart" "R3: the watcher limitation and its remedy"

# --- docs/guest.md ---
S="$(section "$BASE_DIR/docs/guest.md" "## Changing /persist from the host" 2)"
need_section "$S" "guest.md has '## Changing /persist from the host'"
check_para "$S" "project files @@ inbox/" "R2: project files and inbox/ are free to change"
check_para "$S" ".claude @@ .codex @@ .gemini @@ herdr @@ tmux @@ etc/ssh @@ git" "R2: tool state and git operations are left alone"
check_para "$S" "migration @@ rollback @@ nothing under" "R2: change nothing during a migration or rollback"
check_para "$S" "nothing enforces" "R2: nothing enforces the rule"
check_para "$S" "watcher @@ troubleshooting.md" "R3: points to the watcher remedy"
check_para "$S" "Public @@ SMB @@ read and modify @@ etc/ssh @@ credentials @@ accepted" "O2 (a): the Public-share SMB exposure, stated plainly"
check_para "$S" ".DS_Store @@ ._* @@ no remedy is needed" "Q-6: Finder leaves no .DS_Store/AppleDouble files"

# --- qnap-dxe-plan.md ---
PLAN="$BASE_DIR/qnap-dxe-plan.md"
S="$(section "$PLAN" "### DQ4" 3)"
need_section "$S" "qnap-dxe-plan.md has the DQ4 section"
check_para "$S" "**Status @@ host-path @@ DX_PERSIST_STORAGE @@ docs/lifecycle.md" "DQ4 status records the /persist host-path bind"
if grep -Fq "/share/" "$PLAN"; then test_fail "qnap-dxe-plan.md names no /share/ path"; else test_pass "qnap-dxe-plan.md names no /share/ path"; fi

# --- docs/qnap-runbook.md, docs/configuration.md ---
RB="$(cat "$BASE_DIR/docs/qnap-runbook.md")"
for n in Public SMB "read and modify"; do check_has "$RB" "$n" "qnap-runbook still states the exposure: $n"; done
CF="$(cat "$BASE_DIR/docs/configuration.md")"
for f in DX_PERSIST_STORAGE DX_PERSIST_HOST_ROOT DX_PERSIST_HOST_MOUNT_SENTINEL; do
    check_has "$(grep -F "| \`$f\`" <<<"$CF" | sed -n 1p)" "$f" "configuration: table row for $f"
done
check_has "$CF" "DX_PERSIST_FRESH_START" "configuration: DX_PERSIST_FRESH_START is described"

# --- bin/dx-recreate: banner (behaviour) and header comment ---
FAKES="$(fake_tool_dir_create "$TMP_ROOT")" || exit 1
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR"
BANNER="$(env -i PATH="$FAKES:/usr/bin:/bin" HOME="$HOME_DIR" "$BASE_DIR/bin/dx-recreate" 2>/dev/null </dev/null | sed -n 1p)"
case "$BANNER" in
    "Recreating DX environment ("*) test_pass "dx-recreate banner starts as before" ;;
    *) test_fail "dx-recreate banner starts as before (got '$BANNER')" ;;
esac
check_has "$BANNER" "preserves /nix" "dx-recreate banner still says it preserves /nix"
check_has "$BANNER" "host directory" "dx-recreate banner covers a host directory /persist"
if grep -Fq "preserves /nix and /persist)" <<<"$BANNER"; then
    test_fail "dx-recreate banner no longer says the unqualified 'preserves /nix and /persist)'"
else
    test_pass "dx-recreate banner no longer says the unqualified 'preserves /nix and /persist)'"
fi
HDR="$(grep '^#' "$BASE_DIR/bin/dx-recreate")"
check_has "$HDR" "host directory" "dx-recreate header comment covers a host directory /persist"

# --- bin/lib/dx-runtime.sh: where rsync runs ---
RT="$(cat "$BASE_DIR/bin/lib/dx-runtime.sh")"
if grep -F 'from $DX_IMAGE' <<<"$RT" | grep -Fq rsync; then
    test_fail "dx-runtime.sh no longer says rsync runs from \$DX_IMAGE"
elif grep -F 'from $DX_IMAGE' <<<"$RT" >/dev/null; then
    test_fail "dx-runtime.sh no longer says anything runs 'from \$DX_IMAGE'"
else
    test_pass "dx-runtime.sh no longer says anything runs 'from \$DX_IMAGE'"
fi
check_has "$(grep -A2 "rsync operations" <<<"$RT")" "nix volume" "dx-runtime.sh says rsync runs from the guest's nix volume"

# --- the live suite's manual-removal hint ---
LIVE="$(cat "$BASE_DIR/tests/test_persist_host_dir_live.sh")"
check_has "$LIVE" 'docker_bin="$(dxe_runtime_call dx_runtime_docker_require_bin' "live hint: docker binary from the adapter's discovery"
check_has "$LIVE" "docker_bin=docker" "live hint: falls back to the word docker"
for bad in container-station /share/; do
    if grep -Fq -- "$bad" <<<"$LIVE"; then test_fail "live hint: no literal '$bad' in the live suite"; else test_pass "live hint: no literal '$bad' in the live suite"; fi
done

print_summary
exit_with_code
