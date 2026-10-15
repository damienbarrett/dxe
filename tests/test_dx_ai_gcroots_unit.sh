#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# dx-ai GC roots, unit cases (fix/dx-ai-gcroot): the edges of
# dx_ai_root_generation, dx_ai_reconcile_roots, dx_ai_discard_stages and
# dx_ai_main_recover that tests/test_dx_ai_gcroots.sh (the acceptance suite,
# which pins the contract R1-R5 against a Nix-shaped fake and real Nix) does
# not reach: profile shapes Nix never makes, a failing chmod around the
# nix-store call, symlinked or corrupt state, and the stage sweep itself.
# The fake nix-store here only records its argv and the generation
# directory's owner-write bit at the moment it ran; the acceptance suite's
# fake models what real Nix does with the call.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

test_section "dx-ai GC roots: unit cases"

AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
# shellcheck source=/dev/null
source "$AI_SCRIPT"

fixture="" # assigned by dxe_test_mktemp_dir; declared for ShellCheck (SC2154)
dxe_test_mktemp_dir fixture "${TMPDIR:-/tmp}/dxe-ai-gcroots-unit.XXXXXX"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT

fake_bin="$(fake_tool_dir_create "$fixture")" || { echo "could not create fake tools" >&2; exit 1; }
fake_tool_write "$fake_bin" nix-store '
printf "nix-store %s\n" "$*" >> "${UNIT_NIX_LOG:?}"
printf "%s\n" "$(ls -ld "$(dirname "$2")" | cut -c3)" >> "${UNIT_NIX_LOG:?}.mode"
case "$2" in *"${UNIT_NIX_FAIL:-/no-injected-failure/}"*) echo "error: injected add-root failure for $2" >&2; exit 1 ;; esac
printf "%s\n" "$2"'
for gc_tool in nix nix-collect-garbage nix-env; do
    fake_tool_write "$fake_bin" "$gc_tool" 'echo "fake: dx-ai must never call this here" >&2; exit 97'
done
PATH="$fake_bin:$PATH"
UNIT_NIX_LOG="$fixture/nix.log"
export UNIT_NIX_LOG

if [ "$(command -v nix-store)" = "$fake_bin/nix-store" ] && declare -F dx_ai_root_generation >/dev/null \
    && declare -F dx_ai_reconcile_roots >/dev/null && declare -F dx_ai_discard_stages >/dev/null \
    && declare -F dx_ai_main_recover >/dev/null; then
    test_pass "fixture: nix-store resolves to the recording fake and the GC-root functions are defined"
else
    test_fail "fixture: nix-store resolves to the recording fake and the GC-root functions are defined"
fi

log_reset() { : > "$UNIT_NIX_LOG"; : > "$UNIT_NIX_LOG.mode"; }
calls() { cat "$UNIT_NIX_LOG" 2>/dev/null; }
owner_writable() { [ "$(ls -ld "$1" | cut -c3)" = w ]; }

# A Nix-shaped generation: profile -> profile-1-link -> <store path>, the
# metadata dx-ai's own validation reads, read-only like every published one.
make_generation() { # make_generation <dir> <predecessor>
    mkdir -p "$1"
    printf '%s\n' "$2" > "$1/.predecessor"
    ln -s "/nix/store/00000000000000000000000000000000-${1##*/}-profile" "$1/profile-1-link"
    ln -s profile-1-link "$1/profile"
    chmod -R a-w "$1"
}

# Recording stubs for the destructive commands, so a guard that fails can
# only write to the log (tests/test_dx_ai_gcroots.sh has the real sweep).
destructive_stubs() {
    rm() { printf 'rm %s\n' "$*" >> "$fixture/destructive.log"; }
    chmod() { printf 'chmod %s\n' "$*" >> "$fixture/destructive.log"; }
    mv() { printf 'mv %s\n' "$*" >> "$fixture/destructive.log"; }
    find() { printf 'find %s\n' "$*" >> "$fixture/destructive.log"; }
    chown() { printf 'chown %s\n' "$*" >> "$fixture/destructive.log"; }
}

# --- dx_ai_root_generation --------------------------------------------------

(
    gen="$fixture/root-writable/gen"
    make_generation "$gen" ""
    command chmod u+w "$gen"
    log_reset
    if dx_ai_root_generation "$gen" >/dev/null 2>&1 \
        && [ "$(calls)" = "nix-store --add-root $gen/profile-1-link --indirect -r /nix/store/00000000000000000000000000000000-gen-profile" ] \
        && [ "$(cat "$UNIT_NIX_LOG.mode")" = w ] && owner_writable "$gen"; then
        test_pass "root: an owner-writable generation (a stage being published) is rooted as it is and stays writable"
    else
        test_fail "root: an owner-writable generation (a stage being published) is rooted as it is and stays writable (calls: $(calls | tr '\n' '|'))"
    fi
)

(
    gen="$fixture/root-readonly/gen"
    make_generation "$gen" ""
    log_reset
    out="$(dx_ai_root_generation "$gen" 2>/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(cat "$UNIT_NIX_LOG.mode")" = w ] && ! owner_writable "$gen"; then
        test_pass "root: a read-only generation is writable only while nix-store runs, and nix-store's own output is not dx-ai's"
    else
        test_fail "root: a read-only generation is writable only while nix-store runs, and nix-store's own output is not dx-ai's (rc $rc; stdout: $out; mode during call: $(cat "$UNIT_NIX_LOG.mode"))"
    fi
)

(
    for shape in absolute nested parent; do
        gen="$fixture/root-shape-$shape/gen"
        mkdir -p "$gen/sub"
        case "$shape" in
            absolute) ln -s /nix/store/00000000000000000000000000000000-profile "$gen/profile" ;;
            nested) ln -s /nix/store/00000000000000000000000000000000-profile "$gen/sub/profile-1-link"; ln -s sub/profile-1-link "$gen/profile" ;;
            parent) ln -s .. "$gen/profile" ;;
        esac
        log_reset
        if dx_ai_root_generation "$gen" >/dev/null 2>&1 || [ -n "$(calls)" ]; then
            test_fail "root: a profile link Nix never makes ($shape) is refused without a nix-store call (calls: $(calls | tr '\n' '|'))"
        else
            test_pass "root: a profile link Nix never makes ($shape) is refused without a nix-store call"
        fi
    done
)

(
    gen="$fixture/root-dangling/gen"
    mkdir -p "$gen"
    ln -s profile-1-link "$gen/profile"
    log_reset
    if dx_ai_root_generation "$gen" >/dev/null 2>&1 || [ -n "$(calls)" ]; then
        test_fail "root: a profile naming a generation link that is missing is refused without a nix-store call"
    else
        test_pass "root: a profile naming a generation link that is missing is refused without a nix-store call"
    fi
)

(
    gen="$fixture/root-unlock-fails/gen"
    make_generation "$gen" ""
    log_reset
    chmod() { [ "$1" != u+w ] || return 1; command chmod "$@"; }
    if dx_ai_root_generation "$gen" >/dev/null 2>&1 || [ -n "$(calls)" ] || owner_writable "$gen"; then
        test_fail "root: a generation that cannot be made writable is not rooted (non-zero, no nix-store call, still read-only)"
    else
        test_pass "root: a generation that cannot be made writable is not rooted (non-zero, no nix-store call, still read-only)"
    fi
)

(
    gen="$fixture/root-relock-fails/gen"
    make_generation "$gen" ""
    log_reset
    chmod() { [ "$1" != u-w ] || return 1; command chmod "$@"; }
    if dx_ai_root_generation "$gen" >/dev/null 2>&1; then
        test_fail "root: a generation left writable after the call is a failure, even though nix-store succeeded"
    else
        test_pass "root: a generation left writable after the call is a failure, even though nix-store succeeded"
    fi
)

# --- dx_ai_discard_stages ---------------------------------------------------

(
    generations="$fixture/discard/generations"
    mkdir -p "$generations/.staging-ro/pins" "$generations/.staging-rw" "$generations/kept" "$fixture/discard/target"
    printf 'x\n' > "$generations/.staging-ro/pins/agy.json"
    printf 'x\n' > "$fixture/discard/target/file"
    ln -s ../target "$generations/.staging-link"
    chmod -R a-w "$generations/.staging-ro"
    if dx_ai_discard_stages "$generations" 2>/dev/null \
        && [ ! -e "$generations/.staging-ro" ] && [ ! -e "$generations/.staging-rw" ] && [ ! -L "$generations/.staging-link" ] \
        && [ -f "$fixture/discard/target/file" ] && [ -d "$generations/kept" ]; then
        test_pass "discard: removes read-only and writable stages and a stage symlink (never what it points at), and nothing else"
    else
        test_fail "discard: removes read-only and writable stages and a stage symlink (never what it points at), and nothing else ($(ls -a "$generations" | tr '\n' ' '))"
    fi
    if dx_ai_discard_stages "$fixture/discard/empty" 2>/dev/null; then
        test_pass "discard: a generations directory with no stage (or none at all) is a no-op"
    else
        test_fail "discard: a generations directory with no stage (or none at all) is a no-op"
    fi
)

(
    generations="$fixture/discard-fails/generations"
    mkdir -p "$generations/.staging-stuck"
    rm() { [ "$1" != -rf ] || return 1; command rm "$@"; }
    err="$(dx_ai_discard_stages "$generations" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && grep -Fqx 'Warning: could not remove abandoned AI generation stage .staging-stuck.' <<<"$err"; then
        test_pass "discard: a stage that cannot be removed is a Warning naming it, never a failure"
    else
        test_fail "discard: a stage that cannot be removed is a Warning naming it, never a failure (rc $rc; stderr: $err)"
    fi
)

# --- dx_ai_reconcile_roots --------------------------------------------------

(
    state="$fixture/fresh/state"
    log_reset
    if dx_ai_reconcile_roots "$state" 2>/dev/null && [ -z "$(calls)" ] && [ ! -e "$state" ]; then
        test_pass "reconcile: a guest with no AI state yet roots nothing and creates nothing"
    else
        test_fail "reconcile: a guest with no AI state yet roots nothing and creates nothing"
    fi
    mkdir -p "$state/generations/.staging-old"
    if dx_ai_reconcile_roots "$state" 2>/dev/null && [ -z "$(calls)" ] && [ ! -e "$state/generations/.staging-old" ]; then
        test_pass "reconcile: with nothing published it still removes an abandoned stage, and roots nothing"
    else
        test_fail "reconcile: with nothing published it still removes an abandoned stage, and roots nothing"
    fi
)

(
    real="$fixture/linked/real"
    mkdir -p "$real/state/generations/.staging-old" "$real/generations/.staging-old" "$fixture/linked/state"
    make_generation "$real/state/generations/gen-a" ""
    ln -s generations/gen-a "$real/state/current"
    ln -s "$real/state" "$fixture/linked/state-link"
    ln -s "$real/generations" "$fixture/linked/state/generations"
    log_reset
    : > "$fixture/destructive.log"
    (
        destructive_stubs
        dx_ai_reconcile_roots "$fixture/linked/state-link"
        dx_ai_reconcile_roots "$fixture/linked/state"
    ) 2>/dev/null; rc=$?
    if [ "$rc" -eq 0 ] && [ -z "$(calls)" ] && [ ! -s "$fixture/destructive.log" ] \
        && [ -d "$real/state/generations/.staging-old" ] && [ -d "$real/generations/.staging-old" ]; then
        test_pass "reconcile: never follows a symlinked state root or generations directory (nothing removed, nothing rooted)"
    else
        test_fail "reconcile: never follows a symlinked state root or generations directory (nothing removed, nothing rooted) (calls: $(calls | tr '\n' '|'); destructive: $(tr '\n' '|' < "$fixture/destructive.log"))"
    fi
)

(
    i=0
    for pointer in /elsewhere/gen-a 'generations/bad!name' generations/.hidden generations/missing; do
        i=$((i + 1))
        state="$fixture/bad-current-$i/state"
        make_generation "$state/generations/gen-a" ""
        ln -s "$pointer" "$state/current"
        log_reset
        err="$(dx_ai_reconcile_roots "$state" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ] && [ -z "$(calls)" ] && [ -z "$err" ]; then
            test_pass "reconcile: a current pointer that names no retained generation ($pointer) roots nothing and says nothing (--recover reports it)"
        else
            test_fail "reconcile: a current pointer that names no retained generation ($pointer) roots nothing and says nothing (--recover reports it) (rc $rc; calls: $(calls | tr '\n' '|'); stderr: $err)"
        fi
    done
)

(
    i=0
    for predecessor in '' gen-gone 'bad!name' gen-link; do
        i=$((i + 1))
        state="$fixture/pred-$i/state"
        make_generation "$state/generations/gen-a" "$predecessor"
        make_generation "$fixture/pred-$i/elsewhere" ""
        ln -s ../../elsewhere "$state/generations/gen-link"
        ln -s generations/gen-a "$state/current"
        log_reset
        err="$(dx_ai_reconcile_roots "$state" 2>&1)"; rc=$?
        if [ "$rc" -eq 0 ] && [ -z "$err" ] \
            && [ "$(calls)" = "nix-store --add-root $state/generations/gen-a/profile-1-link --indirect -r /nix/store/00000000000000000000000000000000-gen-a-profile" ]; then
            test_pass "reconcile: a predecessor that is ${predecessor:-empty} roots only current, quietly"
        else
            test_fail "reconcile: a predecessor that is ${predecessor:-empty} roots only current, quietly (rc $rc; calls: $(calls | tr '\n' '|'); stderr: $err)"
        fi
    done
)

(
    state="$fixture/warn/state"
    make_generation "$state/generations/gen-a" gen-p
    make_generation "$state/generations/gen-p" ""
    ln -s generations/gen-a "$state/current"
    log_reset
    export UNIT_NIX_FAIL=/generations/gen-a/
    err="$(dx_ai_reconcile_roots "$state" 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && grep -Fqx 'Warning: could not register a GC root for AI generation gen-a' <<<"$err" \
        && ! grep -Fq 'gen-p' <<<"$(grep '^Warning:' <<<"$err")" \
        && [ "$(calls | sed -n 2p)" = "nix-store --add-root $state/generations/gen-p/profile-1-link --indirect -r /nix/store/00000000000000000000000000000000-gen-p-profile" ] \
        && ! owner_writable "$state/generations/gen-a" && ! owner_writable "$state/generations/gen-p"; then
        test_pass "reconcile: an unrootable current is a Warning naming it, and its predecessor is still rooted"
    else
        test_fail "reconcile: an unrootable current is a Warning naming it, and its predecessor is still rooted (rc $rc; calls: $(calls | tr '\n' '|'); stderr: $err)"
    fi
)

# --- dx_ai_main_recover -----------------------------------------------------

(
    state="$fixture/recover-none/state"
    make_generation "$state/generations/gen-a" ""
    mkdir -p "$state/generations/.staging-old"
    ln -s generations/gen-a "$state/current"
    log_reset
    err="$(dx_ai_main_recover "$state" 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -Fqx 'Error: current AI generation is incomplete.' <<<"$err" \
        && [ "$(calls)" = "nix-store --add-root $state/generations/gen-a/profile-1-link --indirect -r /nix/store/00000000000000000000000000000000-gen-a-profile" ] \
        && [ ! -e "$state/generations/.staging-old" ] && [ "$(readlink "$state/current")" = generations/gen-a ]; then
        test_pass "recover: reconciles (stage removed, current rooted) before a recovery that then fails, and the failure is its result"
    else
        test_fail "recover: reconciles (stage removed, current rooted) before a recovery that then fails, and the failure is its result (rc $rc; calls: $(calls | tr '\n' '|'); stderr: $err)"
    fi
)

print_summary
exit_with_code
