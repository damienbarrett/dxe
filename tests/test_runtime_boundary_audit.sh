#!/bin/bash
# tier: unit
# bash32: no
set -uo pipefail

# Branch 11 / Phase 1-2 (qnap-dxe-plan.md DQ2, Phase 1 item 6): automated
# source audit. Fails if any file under bin/ OTHER THAN the runtime adapters
# themselves (bin/lib/dx-runtime-apple.sh, bin/lib/dx-runtime-docker.sh --
# extended to the latter in Phase 2, since it is the docker-ssh adapter's
# own legitimate home for both a real local `container` reference and the
# literal token "container" as a remote `docker container <verb>` argument;
# further extended, WP8.3 step 3, to bin/lib/dx-runtime-docker-*.sh -- the
# facade's own four implementation files the docker-ssh adapter was split
# into, each carrying the same legitimate `docker container <verb>` text)
# invokes a raw Apple `container` lifecycle verb
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

# Branch 11 / Phase 3, Increment 4 (docs/refactor/direct-volume-storage.md):
# besides a raw Apple `container` verb, any fully-spelled dx_runtime_apple_*
# or dx_runtime_docker_* name outside the two adapter files is also a
# boundary leak -- it reaches one runtime's adapter directly, bypassing
# dx_runtime.sh's dispatch, so it runs unconditionally regardless of
# DX_RUNTIME (bin/lib/dx-container.sh's dx_container_list_names did exactly
# this before this increment fixed it). A dynamic dispatch construction like
# dx_runtime.sh's own "dx_runtime_docker_$op" does not match this pattern
# (the name must be fully spelled out, immediately followed by a word
# boundary -- a trailing "$op" is not one), so bin/lib/dx-runtime.sh's own
# dispatcher needs no exception here.
RUNTIME_PREFIX_PATTERN='\bdx_runtime_(apple|docker)_[A-Za-z_][A-Za-z0-9_]*\b'

# The audit logic itself, callable against an arbitrary root so it can be
# proven red/green against disposable fixtures below before trusting it
# against the real tree.
audit_bin_tree() {
    local root="$1" file relfile matches content trimmed
    matches=""
    # WP1.9 (findings.md, 2026-09-29): scan git-tracked files only. `find`
    # used to walk the raw filesystem, so an untracked, git-ignored file
    # under bin/ -- e.g. a local editor/tool config such as
    # bin/.claude/settings.local.json -- could trip the audit despite not
    # being part of the repository's production shell at all; it is not
    # even a subject this audit has any business having an opinion about.
    # `git ls-files` restricts the walk to what the repository actually
    # tracks, which is exactly this audit's subject matter -- an
    # untracked/ignored file is as invisible to it as it would be to
    # anyone cloning the repo fresh.
    while IFS= read -r -d '' relfile; do
        file="$root/$relfile"
        [ -f "$file" ] || continue
        case "$file" in */lib/dx-runtime-apple.sh|*/lib/dx-runtime-docker.sh|*/lib/dx-runtime-docker-*.sh) continue ;; esac
        while IFS= read -r line; do
            [ -n "$line" ] || continue
            # Pure comment lines (only whitespace before the '#') are never
            # a real invocation. Two independent bugs here, both caught
            # 2026-09-27 (Branch 11 / Phase 2) by a new dx-runtime-docker.sh
            # comment that happened to match no OTHER exception below and so
            # exposed both: (1) testing against "$line" itself (grep -n's raw
            # "NUM:content" output) rather than the file content only ever
            # matches a comment starting at column 0 of its OWN grep record,
            # which never happens once grep's numeric prefix is prepended;
            # (2) in a glob/case pattern (unlike a regex), "*" is an
            # independent "any characters" wildcard, not a quantifier on the
            # PRECEDING atom -- so "[[:space:]]*'#'*" does not mean "zero or
            # more spaces, then #", it means "one whitespace char, then
            # anything, then a literal #, then anything", which both
            # requires at least one leading space (so it never matched a
            # column-0 comment even with bug 1 fixed) and, worse, would
            # accept a REAL call as "pure comment" whenever it starts with
            # whitespace and has a bare "#" anywhere later (an inline
            # trailing comment on indented code). Fixed properly: strip
            # grep's prefix, strip leading whitespace with the standard
            # bash idiom, then test literally for a leading "#".
            content="${line#*:}"
            trimmed="${content#"${content%%[![:space:]]*}"}"
            case "$trimmed" in '#'*) continue ;; esac
            # Dated, reasoned exceptions -- human-readable text that
            # happens to match the verb shape, not a real call. Each one
            # named here was confirmed absent from bin/lib/dx-runtime-apple.sh
            # and every other bin/ file's actual `container` invocations
            # during Branch 11 / Phase 1's migration (2026-09-27).
            case "$line" in
                # Narrative comments naming an operation, not calling it. The
                # `container run`/`container exec`/`container logs` arm below
                # is a substring match, so it already covers every comment
                # that names one of those backtick-quoted operations,
                # including the longer explanatory comments in
                # bin/dx-migrate-persist and bin/lib/dx-ssh-common.sh -- no
                # separate arm needed for those (a narrower arm would be
                # unreachable dead code here, ShellCheck SC2221/SC2222).
                *'`container exec`'*|*'`container run'*|*'`container logs`'*) continue ;;
                # "container system" here is English prose ("Apple container
                # system is not running"), not the `container system` verb.
                *'Apple container system is not running'*) continue ;;
                # Diagnostic/operator-facing message text, not an executed call.
                *'sending container kill'*|*'container kill; terminating'*) continue ;;
                *'Legacy cleanup command: container volume rm'*) continue ;;
                *"confirm with 'container exec"*) continue ;;
                *'(container logs unavailable)'*) continue ;;
                # Branch 11 / Phase 3, Increment 4: bin/dx-lock and
                # bin/dx-status's own read-only lock-audit view are the
                # coordinating session's authorised exceptions (Phase 2's
                # design review). Locking is not a dx_runtime_<op> contract
                # operation at all -- Apple has no lock concept to dispatch
                # to -- so these two names have no dispatch-level equivalent
                # to route through. Scoped to exactly these two files: the
                # same names appearing in any OTHER bin/ file are still a
                # real leak and must still be caught.
                *dx_runtime_docker_lock_audit*|*dx_runtime_docker_lock_release*)
                    case "$file" in */dx-lock|*/dx-status) continue ;; esac
                    ;;
                # Branch 11 / Phase 6 (qnap-dxe-plan.md Phase 6 item 7;
                # coordinating session's design review of
                # docs/refactor/qnap-lifecycle.md, 8894d1e): the
                # whole-operation destructive ownership proof is docker-ssh
                # only (Apple has no DQ6 labels at all), and there is no
                # dx_runtime_<op> contract equivalent to route through
                # without inventing a new contract operation -- only one
                # (unrelated) create-time health flag was pre-authorised
                # for this phase. Same reasoning as the lock exception just
                # above; scoped to exactly the one file that calls it.
                *dx_runtime_docker_destructive_plan_and_verify*)
                    case "$file" in */lib/dx-container.sh) continue ;; esac
                    ;;
            esac
            matches="$matches$file:$line"$'\n'
        done < <(grep -nE "$VERB_PATTERN|$RUNTIME_PREFIX_PATTERN" "$file" 2>/dev/null)
    done < <(git -C "$root" ls-files -z -- bin 2>/dev/null)
    printf '%s' "$matches"
}

# Fixture plumbing for the git-tracked-only scan above: `git ls-files`
# only ever sees paths that are staged or committed, so a disposable
# fixture must be a real git repository with its files added, or the scan
# would see nothing at all and every fixture assertion below would go
# trivially green for the wrong reason. Local, throwaway identity only --
# never touches the developer's real git config, and commit.gpgsign is
# forced off so a host with global commit signing enabled can't hang this
# on a passphrase prompt.
fixture_git_init() {
    local dir="$1"
    git -C "$dir" init -q
    git -C "$dir" config user.email "fixture@example.invalid"
    git -C "$dir" config user.name "Fixture"
    git -C "$dir" config commit.gpgsign false
}

# Stage (and commit, so history reads like a real repo) everything
# currently on disk in the fixture tree, so `git ls-files` reports it as
# tracked. Called after every fixture mutation the scan is meant to see.
fixture_commit() {
    local dir="$1" msg="${2:-fixture}"
    git -C "$dir" add -A
    git -C "$dir" commit -q --allow-empty -m "$msg" >/dev/null
}

# --- Prove the detector bites: a disposable fixture with a real violation
# must be caught (red), and the same fixture with the violation removed
# must be clean (green). This is the increment's red/green evidence,
# without needing to revert real production code.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-runtime-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin/lib"
fixture_git_init "$fixture"
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
container exec "$DX_CONTAINER_NAME" true
EOF
fixture_commit "$fixture" "add dx-example with a raw container call"
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
fixture_commit "$fixture" "fix dx-example to call the runtime contract"
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
fixture_commit "$fixture" "add dx-other.sh with a raw container call"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit still catches a raw call in a bin/lib file other than dx-runtime-apple.sh"
else
    test_fail "audit still catches a raw call in a bin/lib file other than dx-runtime-apple.sh"
fi
rm -f "$fixture/bin/lib/dx-other.sh"
fixture_commit "$fixture" "remove dx-other.sh"

mkdir -p "$fixture/bin/lib"
cat > "$fixture/bin/lib/dx-runtime-apple.sh" <<'EOF'
dx_runtime_apple_volume_delete() { container volume rm "$@"; }
EOF
fixture_commit "$fixture" "add dx-runtime-apple.sh"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit exempts bin/lib/dx-runtime-apple.sh itself"
else
    test_fail "audit exempts bin/lib/dx-runtime-apple.sh itself"
fi
rm -f "$fixture/bin/lib/dx-runtime-apple.sh"
fixture_commit "$fixture" "remove dx-runtime-apple.sh"

cat > "$fixture/bin/lib/dx-runtime-docker.sh" <<'EOF'
dx_runtime_docker_container_running() { dx_runtime_docker_ssh_exec "$1" container inspect --format '{{.State.Running}}' "$2"; }
EOF
fixture_commit "$fixture" "add dx-runtime-docker.sh"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit exempts bin/lib/dx-runtime-docker.sh itself (Phase 2's own adapter)"
else
    test_fail "audit exempts bin/lib/dx-runtime-docker.sh itself (Phase 2's own adapter)"
fi
rm -f "$fixture/bin/lib/dx-runtime-docker.sh"
fixture_commit "$fixture" "remove dx-runtime-docker.sh"

# --- WP8.3 step 3: the docker-ssh adapter's own split implementation files
# (bin/lib/dx-runtime-docker-transport.sh, -identity.sh, -lifecycle.sh,
# -lock.sh) carry the exact same genuine Docker CLI syntax
# (`dx_runtime_docker_cli container inspect ...`, `docker container rm
# ...`, ...) the monolithic file did -- each needs the same exemption, by
# name, or the split itself would trip this audit on real, unchanged
# production code.
for split_file in dx-runtime-docker-transport.sh dx-runtime-docker-identity.sh \
    dx-runtime-docker-lifecycle.sh dx-runtime-docker-lock.sh; do
    cat > "$fixture/bin/lib/$split_file" <<'EOF'
dx_runtime_docker_container_running() { dx_runtime_docker_ssh_exec "$1" container inspect --format '{{.State.Running}}' "$2"; }
EOF
    fixture_commit "$fixture" "add $split_file"
    if [ -z "$(audit_bin_tree "$fixture")" ]; then
        test_pass "audit exempts bin/lib/$split_file (WP8.3 step 3's docker adapter split)"
    else
        test_fail "audit exempts bin/lib/$split_file (WP8.3 step 3's docker adapter split)"
    fi
    rm -f "$fixture/bin/lib/$split_file"
    fixture_commit "$fixture" "remove $split_file"
done

# The */lib/dx-runtime-docker-*.sh glob requires a literal hyphen right
# after "docker" -- a similarly-named file that is NOT one of the four real
# split files (no hyphen: "dockerish", not "docker-ish") must still be
# caught, proving the exemption is scoped to the split's own naming
# convention and not just any file whose name happens to start with
# "dx-runtime-docker".
cat > "$fixture/bin/lib/dx-runtime-dockerish.sh" <<'EOF'
dx_runtime_dockerish_container_running() { container inspect "$1"; }
EOF
fixture_commit "$fixture" "add dx-runtime-dockerish.sh (not a real split file)"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "the dx-runtime-docker-*.sh exemption does not extend to a similarly-named non-split file"
else
    test_fail "the dx-runtime-docker-*.sh exemption does not extend to a similarly-named non-split file"
fi
rm -rf "$fixture"

# --- dx_runtime_apple_*/dx_runtime_docker_* boundary leak (Branch 11 /
# Phase 3, Increment 4): a fully-spelled call to either adapter's own
# namespace, outside the two adapter files, bypasses dx_runtime.sh's
# dispatch and so runs unconditionally regardless of DX_RUNTIME.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-runtime-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin/lib"
fixture_git_init "$fixture"
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
dx_example_list_names() { dx_runtime_apple_container_list_names "$@"; }
EOF
fixture_commit "$fixture" "add dx-example with a raw dx_runtime_apple_* call"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit detects a raw dx_runtime_apple_* call planted in a fixture entrypoint (red)"
else
    test_fail "audit detects a raw dx_runtime_apple_* call planted in a fixture entrypoint (red)"
fi

cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
dx_example_list_names() { dx_runtime_container_list "$@"; }
EOF
fixture_commit "$fixture" "fix dx-example to call the dispatch-level contract"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit is clean once the fixture entrypoint calls the dispatch-level contract instead (green)"
else
    test_fail "audit is clean once the fixture entrypoint calls the dispatch-level contract instead (green)"
fi

# A dynamic dispatch construction ("dx_runtime_docker_$op") is not a fully-
# spelled name and must not be caught -- this is exactly bin/lib/dx-runtime.sh's
# own dispatcher shape, which is not one of the two adapter files but must
# still be exempt.
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
op=container_list
"dx_runtime_docker_$op" "$@"
EOF
fixture_commit "$fixture" "add a dynamic dx_runtime_docker_\$op dispatch"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "audit does not false-positive on a dynamic dx_runtime_<runtime>_\$op dispatch construction"
else
    test_fail "audit does not false-positive on a dynamic dx_runtime_<runtime>_\$op dispatch construction"
fi

# The allow-list is scoped to exactly bin/dx-lock and bin/dx-status calling
# exactly dx_runtime_docker_lock_audit/_release -- the same call from any
# OTHER file must still be caught.
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
dx_runtime_docker_lock_audit
EOF
fixture_commit "$fixture" "add dx-example calling the lock allow-list name"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "the dx-lock/dx-status allow-list does not extend to any other file"
else
    test_fail "the dx-lock/dx-status allow-list does not extend to any other file"
fi
rm -f "$fixture/bin/dx-example"
fixture_commit "$fixture" "remove dx-example"

cat > "$fixture/bin/dx-lock" <<'EOF'
#!/bin/bash
dx_runtime_docker_lock_audit
dx_runtime_docker_lock_release ""
EOF
cat > "$fixture/bin/dx-status" <<'EOF'
#!/bin/bash
dx_runtime_docker_lock_audit
EOF
fixture_commit "$fixture" "add dx-lock and dx-status with their allow-listed calls"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "the dx-lock/dx-status allow-list exempts exactly their own authorised lock calls"
else
    test_fail "the dx-lock/dx-status allow-list exempts exactly their own authorised lock calls ($(audit_bin_tree "$fixture"))"
fi
rm -rf "$fixture"

# --- Regression: the pure-comment-line filter must work at ANY line number,
# not only when grep's own "N:" prefix happens to be short (Branch 11 /
# Phase 2, 2026-09-27 -- see the dated comment on the filter itself). Ten
# padding lines push the real line past single digits; the comment names an
# operation no OTHER exception arm above covers, so a false positive here
# could not hide behind one of those.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-runtime-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin"
fixture_git_init "$fixture"
{
    echo '#!/bin/bash'
    for _ in 1 2 3 4 5 6 7 8 9; do echo '# padding'; done
    echo "# a docker-ssh comment mentioning Apple's own 'container system status' for comparison"
} > "$fixture/bin/dx-example"
fixture_commit "$fixture" "add dx-example with padding and a comment"
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "a pure comment naming a container verb is exempt at a two-digit line number too"
else
    test_fail "a pure comment naming a container verb is exempt at a two-digit line number too"
fi
{
    echo '#!/bin/bash'
    for _ in 1 2 3 4 5 6 7 8 9; do echo '# padding'; done
    echo 'container system status'
} > "$fixture/bin/dx-example"
fixture_commit "$fixture" "replace the comment with a real call"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "a real call at a two-digit line number is still caught (the comment fix did not overreach)"
else
    test_fail "a real call at a two-digit line number is still caught (the comment fix did not overreach)"
fi
rm -rf "$fixture"

# --- WP1.9 (findings.md, 2026-09-29): the scan must only ever look at
# git-tracked files. An untracked, git-ignored file living under bin/ --
# e.g. a local editor/tool config such as bin/.claude/settings.local.json
# -- is not part of the repository's production shell and must never trip
# the audit, no matter what it contains. This reproduces a real baseline
# failure: on a developer host, an ignored bin/.claude/settings.local.json
# containing a `Bash(container run --rm ...)` permission string tripped
# audit_bin_tree, because it enumerated the filesystem (`find`) rather
# than git's tracked-file list.
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-runtime-audit.XXXXXX")"
trap 'rm -rf "$fixture"' EXIT
mkdir -p "$fixture/bin/.claude" "$fixture/bin/lib"
fixture_git_init "$fixture"
cat > "$fixture/bin/dx-example" <<'EOF'
#!/bin/bash
set -euo pipefail
dx_runtime_exec "$DX_CONTAINER_NAME" true
EOF
cat > "$fixture/.gitignore" <<'EOF'
bin/.claude/settings.local.json
EOF
fixture_commit "$fixture" "clean tracked entrypoint plus a gitignore rule"
cat > "$fixture/bin/.claude/settings.local.json" <<'EOF'
{
  "permissions": {
    "allow": [
      "Bash(container run --rm ...)"
    ]
  }
}
EOF
if [ -z "$(audit_bin_tree "$fixture")" ]; then
    test_pass "an untracked, git-ignored file under bin/ (e.g. a local .claude/settings.local.json) is never reported, however it names a runtime verb"
else
    test_fail "an untracked, git-ignored file under bin/ (e.g. a local .claude/settings.local.json) is never reported, however it names a runtime verb"
fi

# Complementary to the case above (and to the very first red case in this
# file, which this narrows down on): the same raw-call string, committed
# in a git-TRACKED .sh file, must still be caught -- restricting the scan
# to tracked files must not blind it to a real tracked violation.
cat > "$fixture/bin/lib/dx-tracked-leak.sh" <<'EOF'
leak() { container run --rm "$1"; }
EOF
fixture_commit "$fixture" "add a tracked file with the same raw call"
if [ -n "$(audit_bin_tree "$fixture")" ]; then
    test_pass "the same raw-call string in a git-tracked .sh file is still caught"
else
    test_fail "the same raw-call string in a git-tracked .sh file is still caught"
fi
rm -rf "$fixture"

# --- The real gate: bin/ as it exists in this checkout. Covers both the
# raw Apple `container` verb check and (Branch 11 / Phase 3, Increment 4)
# the dx_runtime_apple_*/dx_runtime_docker_* boundary-leak check together.
real_matches="$(audit_bin_tree "$BASE_DIR")"
if [ -z "$real_matches" ]; then
    test_pass "no raw container lifecycle call or dx_runtime_apple_*/dx_runtime_docker_* boundary leak remains under bin/ outside the two adapter files (and the dx-lock/dx-status allow-list)"
else
    test_fail "raw container lifecycle call(s) or dx_runtime_apple_*/dx_runtime_docker_* boundary leak(s) found outside the two adapter files: $real_matches"
fi

print_summary
exit_with_code
