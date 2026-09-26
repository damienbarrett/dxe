#!/bin/bash
set -uo pipefail

# Branch 11 / Phase 1 (qnap-dxe-plan.md DQ2, Phase 1 item 6): automated
# source audit. Fails if any file under bin/ OTHER THAN
# bin/lib/dx-runtime-apple.sh invokes a raw Apple `container` lifecycle verb
# (list/inspect/exec/run/create/start/stop/kill/delete/rm/image/volume/
# logs/export/stats/system). tests/ may still call `container` directly
# (approved by the task spec) and is out of this audit's scope entirely
# (only bin/ is scanned).
#
# The detector requires "container" to be immediately followed by
# whitespace and one of the verbs above -- the exact shape of a real
# invocation -- which already excludes the overwhelming majority of prose
# ("Removing container $NAME...", "-- container name", "$container_name").
# A handful of existing comments and human-readable echo/printf messages
# still match that shape today (e.g. "container system" inside "Apple
# container system is not running", or a comment naming `container exec`
# for narrative purposes); each is listed explicitly below as a dated,
# reasoned exception -- never a bare pattern with no explanation -- so a
# NEW raw call cannot hide behind an ever-growing, unreviewed allowlist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "Runtime boundary audit (Branch 11 / Phase 1, item 6)"

VERB_PATTERN='(^|[^A-Za-z0-9_."$.-])container[[:space:]]+(list|inspect|exec|run|create|start|stop|kill|delete|rm|image|volume|logs|export|stats|system)\b'

# The audit logic itself, callable against an arbitrary root so it can be
# proven red/green against disposable fixtures below before trusting it
# against the real tree.
audit_bin_tree() {
    local root="$1" file matches
    matches=""
    while IFS= read -r file; do
        [ -f "$file" ] || continue
        case "$file" in */lib/dx-runtime-apple.sh) continue ;; esac
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            # Pure comment lines (only whitespace before the '#') are never
            # a real invocation.
            case "$line" in [[:space:]]*'#'*) continue ;; esac
            # Dated, reasoned exceptions -- human-readable text that
            # happens to match the verb shape, not a real call. Each one
            # named here was confirmed absent from bin/lib/dx-runtime-apple.sh
            # and every other bin/ file's actual `container` invocations
            # during Branch 11 / Phase 1's migration (2026-09-27).
            case "$line" in
                *'`container exec`'*|*'`container run'*|*'`container logs`'*) continue ;;      # narrative comments naming an operation, not calling it
                *'Apple container system is not running'*) continue ;;                          # "container system" here is English prose ("Apple container system"), not the `container system` verb
                *'sending container kill'*|*'container kill; terminating'*) continue ;;         # diagnostic message text
                *'Legacy cleanup command: container volume rm'*) continue ;;                    # a suggested command printed for the OPERATOR to type by hand, not executed
                *"confirm with 'container exec"*) continue ;;                                   # troubleshooting text telling the operator what to type themselves
                *'(container logs unavailable)'*) continue ;;                                   # diagnostic message text
                *'we asked the container to do, and every `container run` below'* | *"Apple Container's \`container run --rm\`"*) continue ;; # historical/explanatory comment prose
            esac
            matches="$matches$file:$line"$'\n'
        done < <(grep -nE "$VERB_PATTERN" "$file" 2>/dev/null)
    done < <(find "$root/bin" -type f)
    printf '%s' "$matches"
}

# --- Prove the detector bites: a disposable fixture with a real violation
# must be caught (red), and the same fixture with the violation removed
# must be clean (green). This is the increment's red/green evidence,
# without needing to revert real production code.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-runtime-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin/lib"
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
container exec "$DX_CONTAINER_NAME" true
EOF
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit detects a raw container call planted in a fixture entrypoint (red)"
else
    test_fail "audit detects a raw container call planted in a fixture entrypoint (red)"
fi

cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
dx_runtime_exec "$DX_CONTAINER_NAME" true
EOF
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit is clean once the fixture entrypoint calls the runtime contract instead (green)"
else
    test_fail "audit is clean once the fixture entrypoint calls the runtime contract instead (green)"
fi

# The exemption applies ONLY to bin/lib/dx-runtime-apple.sh, not to every
# file under bin/lib/ -- a raw call in any OTHER bin/lib file must still be
# caught.
cat > "$fixture/bin/lib/dx-other.sh" <<'EOF'
other_helper() { container volume rm "$1"; }
EOF
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit still catches a raw call in a bin/lib file other than dx-runtime-apple.sh"
else
    test_fail "audit still catches a raw call in a bin/lib file other than dx-runtime-apple.sh"
fi
rm -f "$fixture/bin/lib/dx-other.sh"

mkdir -p "$fixture/bin/lib"
cat > "$fixture/bin/lib/dx-runtime-apple.sh" <<'EOF'
dx_runtime_apple_volume_delete() { container volume rm "$@"; }
EOF
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit exempts bin/lib/dx-runtime-apple.sh itself"
else
    test_fail "audit exempts bin/lib/dx-runtime-apple.sh itself"
fi
rm -rf "$fixture"

# --- The real gate: bin/ as it exists in this checkout.
real_matches="$(audit_bin_tree "$BASE_DIR")"
if [ -z "$real_matches" ]; then
    test_pass "no raw Apple container lifecycle call remains under bin/ outside bin/lib/dx-runtime-apple.sh"
else
    test_fail "raw container lifecycle call(s) found outside bin/lib/dx-runtime-apple.sh: $real_matches"
fi

print_summary
exit_with_code
