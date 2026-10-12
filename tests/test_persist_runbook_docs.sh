#!/bin/bash
# tier: unit
# bash32: yes
# coverage: no
# WP6.6 (spec R2, R30, section 6, 6.1 and R35): the migration runbook, the
# operator's procedure for moving a QNAP guest's /persist from its Docker
# volume into its NAS host directory and back. Section-10 style: fixed-string
# checks scoped to one named section of docs/qnap-runbook.md, local link
# resolution, and no QNAP-specific path. No script runs; nothing is executed.
#
# Interface contract:
#   - File: docs/qnap-runbook.md. Section heading, exactly (level 2):
#         ## 11. Migrating /persist to a NAS host directory
#     The section runs to the next level-2 heading or end of file; ### sub-
#     headings inside it are free. Every check below is a case-insensitive
#     fixed-string match inside the section.
#   - ORDER. These strings appear in this order, each on the same or a later line than the
#     one before (the first occurrence after the previous match counts):
#       dx-persist-inventory, dx-stop-container, dx-persist-migrate,
#       DX_PERSIST_STORAGE=host-path, dx-recreate, dx-status,
#       Verified host-path, host key, keep the old volume,
#       dx-persist-rollback --volume, retired
#   - INVENTORY (the text from the first dx-persist-inventory up to the first
#     dx-stop-container): "blocker", "rsync_check" and "exit 3".
#   - MIGRATE (from the first dx-persist-migrate up to the first
#     DX_PERSIST_STORAGE=host-path): "exit 0", "exit 1", "exit 2", "exit 3",
#     "copying", "ready" and "._*" (the dropped AppleDouble list).
#   - CONFIRM: "configured", "actual" (dx-status), "Verified host-path" (the
#     guest's own check line) and "host key" (unchanged).
#   - KEEP: "never delete" (the old volume is not deleted by the migration).
#   - ROLLBACK, both ways: "--volume", "new volume", "DX_PERSIST_VOLUME",
#     "DX_PERSIST_STORAGE=volume" (switching the profile back), and moving the
#     retired directory aside: a line starting "mv " in a fenced block, plus
#     "new empty directory" (migrating again goes into a fresh directory).
#   - INTERRUPTIONS (R35): "interrupted" with "resume" (rerun after an
#     interrupted copy); "stays `copying`" (failed verification) with
#     "move aside"; ".dxe-persist-dir.XXXXXX" (a hard kill leaves one temp
#     file: remove that one file); "mismatch" (profile changed, not yet
#     recreated: dx-recreate finishes the switch).
#   - THE RULE: "change nothing during the migration", "stopped", "same-second"
#     (the mtime caveat) .
#   - PREREQUISITES found live: "boot the guest once" with "rsync" and "nix-ld";
#     "DX_PERSIST_HOST_MOUNT_SENTINEL" and "sentinel"; the bare image has no
#     "sed" or "awk" ("bare image"); the Public share: "Public", "SMB" and
#     "read and modify" (RW users can read and modify /persist; accepted).
#   - 11.4 (WP6.4c; the subsection from the line starting "### 11.4 " to the
#     next heading): "--inplace", "no rsync temp file" and "partial" (an
#     interrupted copy leaves only a possibly partial final file, which the
#     rerun rewrites); ".dxe-persist-dir.XXXXXX" (the marker-temp remedy
#     stays); the copy and verify containers "dxe-persist-copy-" and
#     "dxe-persist-verify-" and what to do: "still running" (wait, or
#     "docker stop"), otherwise "docker rm" after inspecting it. Each phrase
#     must sit on one line (the match is per line).
#   - MANUAL REMOVAL of a retired or canary directory: "yourself" (the user
#     runs it, not the tooling), "docker run --rm", "--user 0:0", a line with
#     " ls " before the first line starting with or holding "rm -r".
#   - "<qnap-share>" appears in the section; no line anywhere in the file
#     holds "/share/" followed by a name and "_DATA" or any "/share/" path.
#   - Local Markdown links in the whole file resolve.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"

test_section "WP6.6: migration runbook (docs/qnap-runbook.md)"

DOC="$BASE_DIR/docs/qnap-runbook.md"
HEADING="## 11. Migrating /persist to a NAS host directory"

SECTION="$(awk -v h="$HEADING" '
    $0 == h { on = 1; print; next }
    on && /^## / { exit }
    on { print }
' "$DOC")"

if [ -n "$SECTION" ]; then
    test_pass "docs/qnap-runbook.md has the section '$HEADING'"
else
    test_fail "docs/qnap-runbook.md has the section '$HEADING'"
fi

has_text() { grep -Fiq -- "$1" <<<"$2"; }
assert_in() { # TEXT NEEDLE LABEL
    if has_text "$2" "$1"; then test_pass "$3"; else test_fail "$3 (missing '$2')"; fi
}
assert_text() { assert_in "$SECTION" "$1" "section mentions: $2"; }

# first_line TEXT NEEDLE AFTER -- first line number >= AFTER holding NEEDLE.
first_line() {
    printf '%s\n' "$1" | grep -Fin -- "$2" | cut -d: -f1 | awk -v a="$3" '$1 >= a { print; exit }'
}

# range_between TEXT START END -- lines from the first START to the first END after it.
range_between() {
    local s e
    s="$(first_line "$1" "$2" 0)"
    [ -n "$s" ] || return 0
    e="$(first_line "$1" "$3" "$s")"
    if [ -n "$e" ]; then printf '%s\n' "$1" | sed -n "${s},${e}p"; else printf '%s\n' "$1" | sed -n "${s},\$p"; fi
}

# ORDER.
prev=0
ordered=yes
detail=""
for anchor in "dx-persist-inventory" "dx-stop-container" "dx-persist-migrate" \
    "DX_PERSIST_STORAGE=host-path" "dx-recreate" "dx-status" "Verified host-path" \
    "host key" "keep the old volume" "dx-persist-rollback --volume" "retired"; do
    line="$(first_line "$SECTION" "$anchor" "$prev")"
    if [ -z "$line" ]; then ordered=no; detail="$detail '$anchor' not found after line $prev;"; continue; fi
    prev="$line"
done
if [ "$ordered" = yes ]; then
    test_pass "inventory, stop, migrate, switch, recreate, confirm, keep, rollback appear in order"
else
    test_fail "inventory, stop, migrate, switch, recreate, confirm, keep, rollback appear in order:$detail"
fi

INV="$(range_between "$SECTION" "dx-persist-inventory" "dx-stop-container")"
for n in "blocker" "rsync_check" "exit 3"; do
    assert_in "$INV" "$n" "inventory step (before the stop step) covers: $n"
done

MIG="$(range_between "$SECTION" "dx-persist-migrate" "DX_PERSIST_STORAGE=host-path")"
for n in "exit 0" "exit 1" "exit 2" "exit 3" "copying" "ready" '._*'; do
    assert_in "$MIG" "$n" "migrate step (before the switch) covers: $n"
done

assert_text "configured" "dx-status configured source"
assert_text "actual" "dx-status actual source"
assert_text "never delete" "the old volume is never deleted by the migration"
assert_text "--volume" "rollback names the new volume with --volume"
assert_text "new volume" "rollback copies into a new volume"
assert_text "DX_PERSIST_VOLUME" "rollback profile volume name"
assert_text "DX_PERSIST_STORAGE=volume" "rollback switches the profile back to volume mode"
assert_text "new empty directory" "migrating again goes into a new empty directory"
if grep -q '^mv ' <<<"$SECTION"; then
    test_pass "section shows an mv line to move the retired directory aside"
else
    test_fail "section shows an mv line to move the retired directory aside"
fi

assert_text "interrupted" "an interrupted copy"
assert_text "resume" "rerun resumes"
assert_text 'stays `copying`' "failed verification keeps the marker copying"
assert_text "move aside" "abandon by moving the directory aside"
assert_text ".dxe-persist-dir.XXXXXX" "the temp file a hard kill leaves"
assert_text "mismatch" "profile changed before the recreate"

# WP6.4c: 11.4 once the copy runs with --inplace in named copy/verify containers.
SUB114="$(awk '/^### 11\.4 / { on = 1; print; next } on && /^###* / { exit } on { print }' <<<"$SECTION")"
for n in "--inplace" "no rsync temp file" "partial" ".dxe-persist-dir.XXXXXX" \
    "dxe-persist-copy-" "dxe-persist-verify-" "still running" "docker stop" "docker rm"; do
    assert_in "$SUB114" "$n" "11.4 (an interrupted copy) covers: $n"
done

assert_text "change nothing during the migration" "the change-nothing rule"
assert_text "stopped" "the guest is stopped"
assert_text "same-second" "the same-second mtime caveat"

assert_text "boot the guest once" "boot once so the essentials include rsync"
assert_text "rsync" "rsync prerequisite"
assert_text "nix-ld" "nix-ld prerequisite"
assert_text "DX_PERSIST_HOST_MOUNT_SENTINEL" "the mount sentinel setting"
assert_text "sentinel" "a sentinel file at the share root"
assert_text "bare image" "the bare image lacks sed and awk"
assert_text "awk" "awk named"
assert_text "Public" "the Public share"
assert_text "SMB" "SMB exposure"
assert_text "read and modify" "RW users can read and modify /persist"

assert_text "yourself" "manual removal is run by the user"
assert_text "docker run --rm" "removal through a one-off container"
assert_text "--user 0:0" "removal as root"
ls_line="$(first_line "$SECTION" " ls " 0)"
rm_line="$(first_line "$SECTION" "rm -r" 0)"
if [ -n "$ls_line" ] && [ -n "$rm_line" ] && [ "$ls_line" -lt "$rm_line" ]; then
    test_pass "a look (ls) comes before the delete"
else
    test_fail "a look (ls) comes before the delete (ls line '$ls_line', rm line '$rm_line')"
fi
assert_text "<qnap-share>" "the <qnap-share> placeholder"

if grep -Fq -- '/share/' "$DOC"; then
    test_fail "docs/qnap-runbook.md holds no /share/ path"
else
    test_pass "docs/qnap-runbook.md holds no /share/ path"
fi

broken=""
while IFS= read -r reference; do
    target=${reference#']('}; target=${target%%#*}
    case "$target" in ''|http:*|https:*|mailto:*) continue ;; esac
    [ -e "$(dirname "$DOC")/$target" ] || broken="$broken$target "
done < <(grep -oE '\]\([^)]+' "$DOC" || true)
if [ -z "$broken" ]; then
    test_pass "local links in docs/qnap-runbook.md resolve"
else
    test_fail "local links in docs/qnap-runbook.md resolve (broken: $broken)"
fi

print_summary
exit_with_code
