#!/bin/bash
# tier: unit
# bash32: no
# coverage: yes
# dx-ai GC roots (fix/dx-ai-gcroot): a published AI generation is always
# protected by a Nix GC root that resolves at its FINAL path.
#
# The bug (live on the QNAP guest, 2026-10-12): dx-ai builds each generation
# in $state/generations/.staging-<id> with `nix profile add --profile
# <stage>/profile`. Nix registers an indirect GC root for the generation link
# it creates, by that link's absolute path string, never resolved:
#   ${NIX_STATE_DIR:-/nix/var/nix}/gcroots/auto/<sha1 of the path>
#       -> <stage>/profile-1-link -> /nix/store/<hash>-profile
# dx_ai_publish_generation then renames the stage to generations/<id>, so the
# root dangles. dx-reclaim's `nix-collect-garbage -d` printed `removing stale
# link from ".../gcroots/auto/..." to ".../.staging-<id>/profile-1-link"` and
# deleted the CURRENT generation's profile, and with it every AI tool.
# Reproduced with real Nix 2.34.8 (nixos/nix container, a uid-1000
# single-user store standing in for dx's, the production
# dx_ai_stage_generation/dx_ai_publish_generation): the same message, then
# `deleting '/nix/store/...-profile'`, then current/profile/bin/codex: No
# such file or directory.
#
# Interface contract (pinned here; scripts/lib/dx-ai-generation.sh):
#
# R1  dx_ai_root_generation <generation-dir>
#     When <gen>/profile is a symlink naming a generation link in the same
#     directory (Nix's own shape: profile -> profile-1-link -> <store path>),
#     registers an indirect GC root at that link's FINAL path by running
#     exactly (the established form, docs/qnap-runbook.md):
#         nix-store --add-root <gen>/profile-1-link --indirect -r <store path>
#     where <store path> is `readlink <gen>/profile-1-link`. Nix replaces the
#     link through a temporary symlink created in <gen> (real Nix as dx:
#     "creating symlink ... Permission denied" on a read-only directory), so
#     when <gen> is not owner-writable -- every published generation is
#     `chmod -R a-w` -- it makes the directory owner-writable first and
#     read-only again afterwards, on success AND on failure. It never
#     rebuilds (no `nix profile`, `nix build`, `nix flake`), never changes
#     what <gen>/profile resolves to, and prints no `Error:`/`Warning:` line
#     itself (its callers own the message). Non-zero when nix-store fails,
#     e.g. when the store path is already gone (real Nix: "is required, but
#     there is no substituter that can build it"). A <gen>/profile that is
#     not a symlink has no store path to root: return 0, no nix-store call.
#
# R2  dx_ai_publish_generation <state> <id> <stage>
#     After moving the stage to generations/<id> and BEFORE pointing current
#     at it, roots generations/<id> via R1 (exactly one nix-store call). If
#     that fails, the publish fails with
#         Error: could not register a GC root for AI generation <id>
#     on stderr, generations/<id> is removed and current is unchanged. On
#     success the generation is read-only exactly as before.
#
# R3  dx_ai_reconcile_roots <state>
#     Runs at the start of every locked dx-ai run (update and --recover),
#     under the publication lock, before anything is staged or recovered:
#       - removes orphaned .staging-* stages (a killed run's; their live
#         Nix root would otherwise pin a full closure until a later publish);
#       - roots current's generation, then the predecessor recorded in its
#         .predecessor, at their final paths via R1 -- healing guests whose
#         only root still names a vanished stage, without rebuilding;
#       - a generation it cannot root (its store path is already gone)
#         prints
#             Warning: could not register a GC root for AI generation <id>
#         and the run continues: an update then builds a replacement.
#
# R4  dx-ai never collects garbage: no `nix-store --gc`/`--delete`,
#     `nix-collect-garbage`, `nix store gc`/`delete`.
#
# R5  dx-ai never edits ${NIX_STATE_DIR:-/nix/var/nix}/gcroots itself: it
#     registers roots only through nix-store, and leaves the dangling auto
#     link a renamed or removed stage leaves behind for Nix's own GC to prune
#     (Nix owns that directory: root-owned under a daemon, scanned under the
#     GC lock). A dangling auto link is not a root -- the GC deletes it, it
#     pins nothing -- so "no root points into .staging-" means: no LIVE root
#     (an auto link whose target exists and is a symlink to a store path)
#     resolves through a .staging- path once dx-ai has finished.
#
# Fakes: `nix profile add` and `nix-store --add-root` below model only what
# the probe measured with real Nix 2.34.8 (nixos/nix:2.34.8, uid-1000 store,
# 2026-10-13): a profile build writes <P>-1-link -> <store>, P ->
# <P>-1-link (relative) and an auto link -> <P>-1-link by its unresolved
# path string; add-root needs the link's directory owner-writable (checked
# on the mode bits, so a root-run kcov container behaves like dx), replaces
# an existing store link, keeps one auto link per path (idempotent), fails
# for a store path that is gone; `--indirect` is accepted. sim_gc_roots
# implements Nix's findRoots for auto links: a target that no longer exists
# is stale (pruned, pins nothing); otherwise the target must itself be a
# symlink whose ONE readlink is a valid store path (a link to <gen>/profile,
# whose readlink is the relative "profile-1-link", roots nothing -- measured;
# an intermediate symlink in the target path, e.g. current/, is followed --
# measured). The real-Nix case at the end runs the same publish against real
# Nix wherever it is available (Linux CI); constitution rule 3.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=test_helpers.sh
source "$SCRIPT_DIR/test_helpers.sh"
# shellcheck source=lib/fake-tools.sh
source "$SCRIPT_DIR/lib/fake-tools.sh"

test_section "dx-ai GC roots at final generation paths"

AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
# shellcheck source=/dev/null
source "$AI_SCRIPT"
dx_ai_load_lock || test_fail "dx_ai_load_lock resolves the publication-lock library"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-ai-gcroots.XXXXXX")"
trap 'chmod -R u+w "$fixture" 2>/dev/null || true; rm -rf "$fixture"' EXIT

# GNU mv -T/-Tf for hosts whose mv lacks it (macOS), as in
# tests/test_section17_dx_ai_runtime.sh: dx_ai_publish_pointer switches
# current with `mv -Tf`.
real_mv="$(command -v mv)"
mv() {
    case "${1:-}" in
        -Tf) rm -f "$3"; "$real_mv" -f "$2" "$3" ;;
        -T)
            [ ! -e "$3" ] && [ ! -L "$3" ] || return 1
            "$real_mv" "$2" "$3"
            ;;
        *) "$real_mv" "$@" ;;
    esac
}

real_path="$PATH"
fake_bin="$(fake_tool_dir_create "$fixture")" || { echo "could not create fake tools" >&2; exit 1; }

# Shared by the fakes: an atomic rename onto a path that may be a symlink to
# a directory (rename(2), like Nix's makeSymlink), and the dx-like
# owner-write check.
fake_nix_common='
log="${FAKE_NIX_LOG:?}"; ledger="${FAKE_NIX_LEDGER:?}"
store="${NIX_STORE_DIR:?}"; auto="${NIX_STATE_DIR:?}/gcroots/auto"
rename_over() { if mv --version >/dev/null 2>&1; then mv -fT "$1" "$2"; else mv -fh "$1" "$2"; fi; }
owner_writable() { [ "$(ls -ld "$1" | cut -c3)" = w ]; }
auto_root() {
    local name
    name="$(printf "%s" "$1" | cksum | awk "{print \$1}")"
    ln -s "$1" "$auto/.tmp-$name" && rename_over "$auto/.tmp-$name" "$auto/$name" || return 1
    printf "%s -> %s\n" "$name" "$1" >> "$ledger"
}'

fake_tool_write "$fake_bin" nix "$fake_nix_common"'
printf "nix %s\n" "$*" >> "$log"
if [ "${1:-} ${2:-}" != "profile add" ]; then
    echo "fake nix: unsupported invocation: nix $*" >&2
    exit 98
fi
shift 2
profile=""; installable=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        --profile) profile="$2"; shift 2 ;;
        --extra-experimental-features) shift 2 ;;
        --accept-flake-config) shift ;;
        *) installable="$1"; shift ;;
    esac
done
[ -n "$profile" ] && [ -n "$installable" ] || { echo "fake nix: profile add needs --profile and an installable" >&2; exit 98; }
case "$profile" in /*) : ;; *) profile="$PWD/$profile" ;; esac
[ ! -e "$profile-1-link" ] && [ ! -L "$profile-1-link" ] || { echo "fake nix: only a fresh profile is modelled" >&2; exit 98; }
owner_writable "$(dirname "$profile")" || { echo "error: creating symlink \"$profile-1-link.tmp-$$\": Permission denied" >&2; exit 1; }
n=$(( $(ls "$store" | wc -l) + 1 ))
out="$store/$(printf "%032d" "$n")-profile"
mkdir -p "$out/bin"
while IFS= read -r tool || [ -n "$tool" ]; do
    [ -n "$tool" ] || continue
    case " ${FAKE_NIX_PROFILE_OMIT:-} " in *" $tool "*) continue ;; esac
    printf "#!/bin/sh\nexit 0\n" > "$out/bin/$tool"
    chmod 0755 "$out/bin/$tool"
done < "${installable%%#*}/.tools-manifest"
printf "{\"version\":3}\n" > "$out/manifest.json"
ln -s "$out" "$profile-1-link.tmp-$$" && rename_over "$profile-1-link.tmp-$$" "$profile-1-link" || exit 1
auto_root "$profile-1-link" || exit 1
ln -s "${profile##*/}-1-link" "$profile.tmp-$$" && rename_over "$profile.tmp-$$" "$profile" || exit 1'

fake_tool_write "$fake_bin" nix-store "$fake_nix_common"'
printf "nix-store %s\n" "$*" >> "$log"
case " $* " in
    *" --gc "*|*" --delete "*) echo "fake nix-store: dx-ai must never collect garbage" >&2; exit 97 ;;
esac
if [ "$#" -ne 5 ] || [ "$1" != --add-root ] || [ "$3" != --indirect ] || [ "$4" != -r ]; then
    echo "fake nix-store: unsupported invocation: nix-store $*" >&2
    exit 98
fi
link="$2"; path="$5"
case "$link" in /*) : ;; *) echo "fake nix-store: the root path must be absolute: $link" >&2; exit 98 ;; esac
if [ -n "${FAKE_NIX_STORE_FAIL_MATCH:-}" ]; then
    case "$link" in *"$FAKE_NIX_STORE_FAIL_MATCH"*) echo "error: injected add-root failure for $link" >&2; exit 1 ;; esac
fi
case "$path" in "$store"/*) : ;; *) echo "error: path '"'"'$path'"'"' is not in the Nix store" >&2; exit 1 ;; esac
[ -d "$path" ] || { echo "error: path '"'"'$path'"'"' is required, but there is no substituter that can build it" >&2; exit 1; }
if [ -e "$link" ] || [ -L "$link" ]; then
    existing="$(readlink "$link" 2>/dev/null || true)"
    case "$existing" in "$store"/*) : ;; *) echo "error: cannot create symlink '"'"'$link'"'"'; already exists" >&2; exit 1 ;; esac
fi
owner_writable "$(dirname "$link")" || { echo "error: creating symlink \"$link.tmp-$$\" -> \"$path\": Permission denied" >&2; exit 1; }
ln -s "$path" "$link.tmp-$$" && rename_over "$link.tmp-$$" "$link" || exit 1
auto_root "$link" || exit 1
printf "%s\n" "$link"'

for gc_tool in nix-collect-garbage nix-env; do
    fake_tool_write "$fake_bin" "$gc_tool" 'printf "%s %s\n" "'"$gc_tool"'" "$*" >> "${FAKE_NIX_LOG:?}"
echo "fake '"$gc_tool"': dx-ai must never call this" >&2
exit 97'
done
PATH="$fake_bin:$PATH"

# Recorded in this (parent) shell before any subshell case, so every case
# below lands in this suite's one results file (tests/lib/harness.sh creates
# it lazily, per process).
if [ "$(command -v nix)" = "$fake_bin/nix" ] && [ "$(command -v nix-store)" = "$fake_bin/nix-store" ] \
    && [ "$(command -v nix-collect-garbage)" = "$fake_bin/nix-collect-garbage" ]; then
    test_pass "fixture: nix, nix-store and nix-collect-garbage resolve to the fakes, never to a real store"
else
    test_fail "fixture: nix, nix-store and nix-collect-garbage resolve to the fakes, never to a real store"
    print_summary
    exit_with_code
fi

# --- fixture helpers ----------------------------------------------------

# A fresh fake Nix world: store, state dir with gcroots/auto, call log and
# the ledger of every auto link the fakes created. Exported for the fakes.
world_new() {
    local w="$1"
    mkdir -p "$w/store" "$w/var/nix/gcroots/auto"
    : > "$w/nix.log"
    : > "$w/ledger"
    NIX_STORE_DIR="$w/store"; NIX_STATE_DIR="$w/var/nix"
    FAKE_NIX_LOG="$w/nix.log"; FAKE_NIX_LEDGER="$w/ledger"
    export NIX_STORE_DIR NIX_STATE_DIR FAKE_NIX_LOG FAKE_NIX_LEDGER
}

make_published() {
    mkdir -p "$1/pins"
    printf '%s\n' '{"aarch64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"},"x86_64-linux":{"version":"1","url":"https://example.invalid/agy","hash":"sha512-test"}}' > "$1/pins/agy.json"
    printf '%s\n' fixture > "$1/flake.nix"
    printf '%s\n' fixture > "$1/flake.lock"
}

# A generation exactly as today's dx-ai leaves it: staged by
# dx_ai_stage_generation, built by `nix profile add` at its .staging-<id>
# path, renamed into place, made read-only, and pointed at by current. Its
# only GC root is Nix's own auto link to the vanished stage.
seed_incident_generation() {
    local published="$1" state="$2" id="$3" stage
    stage="$(dx_ai_stage_generation "$published" "$state" "$id")" || return 1
    dx_ai_install_profile "$stage" >/dev/null || return 1
    "$real_mv" "$stage" "$state/generations/$id" || return 1
    chmod -R a-w "$state/generations/$id" || return 1
    rm -f "$state/current"
    ln -s "generations/$id" "$state/current"
}

# An unrelated dangling auto link that dx-ai must leave alone (R5).
plant_unrelated_root() {
    ln -s "$fixture/elsewhere/gone/profile-1-link" "$NIX_STATE_DIR/gcroots/auto/unrelated-dangling"
    printf '%s\n' "unrelated-dangling -> $fixture/elsewhere/gone/profile-1-link" > "$NIX_STATE_DIR/../planted"
}

# Nix's findRoots over gcroots/auto: one "<store path> <via>" line per live
# root. A target that no longer exists is stale (Nix prunes it; it pins
# nothing); otherwise the target must be a symlink whose single readlink is
# a valid store path.
sim_gc_roots() {
    local auto="$NIX_STATE_DIR/gcroots/auto" link target store_path
    for link in "$auto"/* "$auto"/.[!.]*; do
        [ -L "$link" ] || continue
        target="$(readlink "$link")"
        case "$target" in "$NIX_STORE_DIR"/*) [ -d "$target" ] && printf '%s %s\n' "$target" "$link"; continue ;; esac
        case "$target" in /*) : ;; *) target="$auto/$target" ;; esac
        { [ -e "$target" ] || [ -L "$target" ]; } || continue
        [ -L "$target" ] || continue
        store_path="$(readlink "$target")"
        case "$store_path" in "$NIX_STORE_DIR"/*) [ -d "$store_path" ] && printf '%s %s\n' "$store_path" "$target" ;; esac
    done
    return 0
}

gc_keeps_via() { # gc_keeps_via <store path> <via>
    grep -Fqx "$1 $2" <<<"$(sim_gc_roots)"
}

gc_has_staging_root() {
    grep -Fq '/generations/.staging-' <<<"$(sim_gc_roots)"
}

# The auto directory holds exactly what was planted plus what the fake Nix
# itself registered (latest target per name): dx-ai added and removed
# nothing by hand (R5).
auto_untouched_by_dx_ai() {
    local expected actual link
    expected="$( { cat "$NIX_STATE_DIR/../planted" 2>/dev/null; awk '{ last[$1] = $0 } END { for (n in last) print last[n] }' "$FAKE_NIX_LEDGER"; } | LC_ALL=C sort)"
    actual="$(for link in "$NIX_STATE_DIR/gcroots/auto"/* "$NIX_STATE_DIR/gcroots/auto"/.[!.]*; do
        [ -L "$link" ] || [ -e "$link" ] || continue
        printf '%s -> %s\n' "${link##*/}" "$(readlink "$link")"
    done | LC_ALL=C sort)"
    [ "$expected" = "$actual" ]
}

auto_links_to() { # auto_links_to <target>: how many auto links name it
    local link count=0
    for link in "$NIX_STATE_DIR/gcroots/auto"/*; do
        [ -L "$link" ] && [ "$(readlink "$link")" = "$1" ] && count=$((count + 1))
    done
    printf '%s\n' "$count"
}

# A collected store path (fixture store only).
remove_store_path() {
    case "$1" in
        "$NIX_STORE_DIR"/?*) chmod -R u+w "$1" && rm -rf "$1" ;;
        *) test_fail "fixture: refusing to remove $1 outside the fake store"; return 1 ;;
    esac
}

owner_writable() { [ "$(ls -ld "$1" | cut -c3)" = w ]; }

# Read-only and Nix-shaped: profile -> profile-1-link -> the expected store path.
generation_intact() { # generation_intact <gen> <store path>
    ! owner_writable "$1" && ! owner_writable "$1/flake.nix" \
        && [ "$(readlink "$1/profile")" = profile-1-link ] \
        && [ "$(readlink "$1/profile-1-link")" = "$2" ] \
        && [ -z "$(find "$1" -maxdepth 1 -name '*.tmp-*' 2>/dev/null)" ]
}

have_fn() { declare -F "$1" >/dev/null; }

# dx_ai_main's surroundings, as in section 17: no network, no credentials,
# a fixed generation id, a guest identity for the lock.
main_stubs() {
    id() { printf '%s\n' 1000; }
    date() { printf '%s\n' 20261013T000000Z; }
    boot_id() { printf '%s\n' test-boot-id; }
    process_start() { printf '%s\n' 123; }
    dx_guest_resolve_system() { printf '%s\n' aarch64-linux; }
    dx_ai_tools_for_system() { printf '%s\n' $DX_AI_TOOLS; }
    dx_ai_update_flake() { :; }
    dx_ai_ensure_cached() { :; }
    dx_ai_setup_credentials() { :; }
    dx_ai_ensure_keyring() { :; }
    dx_ai_install_herdr_integrations() { :; }
}
new_id="20261013T000000Z-$$"
export DX_USAGE_SCAN_DIR="$fixture/no-usage-service"

# --- R1: dx_ai_root_generation -------------------------------------------

(
    w="$fixture/r1"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-a || test_fail "R1 fixture: seed an incident-shaped generation"
    gen="$state/generations/gen-a"; sa="$(readlink "$gen/profile-1-link")"
    if [ -n "$(sim_gc_roots)" ] || owner_writable "$gen"; then
        test_fail "R1 fixture: the seeded generation is read-only and unrooted (the incident state)"
    fi
    : > "$FAKE_NIX_LOG"
    if ! have_fn dx_ai_root_generation; then
        test_fail "R1: dx_ai_root_generation exists (scripts/lib/dx-ai-generation.sh)"
        exit 0
    fi
    err="$(dx_ai_root_generation "$gen" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(cat "$FAKE_NIX_LOG")" = "nix-store --add-root $gen/profile-1-link --indirect -r $sa" ]; then
        test_pass "R1: dx_ai_root_generation roots a read-only generation at its final path with exactly one nix-store --add-root call"
    else
        test_fail "R1: dx_ai_root_generation roots a read-only generation at its final path with exactly one nix-store --add-root call (rc $rc; calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"); stderr: $err)"
    fi
    if gc_keeps_via "$sa" "$gen/profile-1-link"; then
        test_pass "R1: a GC then keeps the generation's profile through <gen>/profile-1-link"
    else
        test_fail "R1: a GC then keeps the generation's profile through <gen>/profile-1-link (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if generation_intact "$gen" "$sa"; then
        test_pass "R1: the generation stays read-only, profile -> profile-1-link -> the same store path"
    else
        test_fail "R1: the generation stays read-only, profile -> profile-1-link -> the same store path ($(ls -ld "$gen"))"
    fi
    dx_ai_root_generation "$gen" >/dev/null 2>&1
    if [ "$(auto_links_to "$gen/profile-1-link")" = 1 ] && generation_intact "$gen" "$sa"; then
        test_pass "R1: rooting the same generation again keeps exactly one auto root for its final path"
    else
        test_fail "R1: rooting the same generation again keeps exactly one auto root for its final path ($(auto_links_to "$gen/profile-1-link") links)"
    fi
    if grep -Eq '^nix (profile|build|flake)' "$FAKE_NIX_LOG"; then
        test_fail "R1: rooting never rebuilds (no nix profile/build/flake call)"
    else
        test_pass "R1: rooting never rebuilds (no nix profile/build/flake call)"
    fi
)

(
    w="$fixture/r1-gone"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-a || test_fail "R1 fixture: seed a generation whose profile was collected"
    gen="$state/generations/gen-a"; sa="$(readlink "$gen/profile-1-link")"
    remove_store_path "$sa"
    if ! have_fn dx_ai_root_generation; then
        test_fail "R1: dx_ai_root_generation exists (scripts/lib/dx-ai-generation.sh)"
        exit 0
    fi
    err="$(dx_ai_root_generation "$gen" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && ! owner_writable "$gen" && [ "$(readlink "$gen/profile-1-link")" = "$sa" ] \
        && ! grep -Eq '^(Error|Warning):' <<<"$err"; then
        test_pass "R1: a generation whose store path is gone cannot be rooted: non-zero, still read-only, no Error/Warning line of its own"
    else
        test_fail "R1: a generation whose store path is gone cannot be rooted: non-zero, still read-only, no Error/Warning line of its own (rc $rc; $(ls -ld "$gen"); stderr: $err)"
    fi
)

(
    w="$fixture/r1-dir"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    stage="$(dx_ai_stage_generation "$w/published" "$state" gen-d)"
    mkdir -p "$stage/profile/bin"
    for tool in $DX_AI_TOOLS; do printf '#!/bin/sh\n' > "$stage/profile/bin/$tool"; chmod 0755 "$stage/profile/bin/$tool"; done
    : > "$FAKE_NIX_LOG"
    if ! have_fn dx_ai_root_generation; then
        test_fail "R1: dx_ai_root_generation exists (scripts/lib/dx-ai-generation.sh)"
    elif dx_ai_root_generation "$stage" >/dev/null 2>&1 && [ ! -s "$FAKE_NIX_LOG" ]; then
        test_pass "R1: a profile that is a plain directory has no store path to root: success, no nix-store call"
    else
        test_fail "R1: a profile that is a plain directory has no store path to root: success, no nix-store call (calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"))"
    fi
    # The same holds through publish (R2): nothing to root, nothing called.
    : > "$FAKE_NIX_LOG"
    if dx_ai_publish_generation "$state" gen-d "$stage" >/dev/null 2>&1 && [ "$(readlink "$state/current")" = generations/gen-d ] \
        && [ ! -s "$FAKE_NIX_LOG" ]; then
        test_pass "R2: publishing a plain-directory profile still succeeds and calls no nix-store"
    else
        test_fail "R2: publishing a plain-directory profile still succeeds and calls no nix-store (calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"))"
    fi
)

# --- R2: dx_ai_publish_generation ----------------------------------------

(
    w="$fixture/r2"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    stage="$(dx_ai_stage_generation "$w/published" "$state" gen-n)"
    dx_ai_install_profile "$stage" >/dev/null
    sn="$(readlink "$stage/profile-1-link")"
    if [ -z "$sn" ] || ! gc_has_staging_root; then
        test_fail "R2 fixture: the fake nix profile add roots the stage like real Nix does"
    fi
    : > "$FAKE_NIX_LOG"
    err="$(dx_ai_publish_generation "$state" gen-n "$stage" 2>&1 >/dev/null)"; rc=$?
    gen="$state/generations/gen-n"
    if [ "$rc" -eq 0 ] && [ "$(readlink "$state/current")" = generations/gen-n ] \
        && [ "$(cat "$FAKE_NIX_LOG")" = "nix-store --add-root $gen/profile-1-link --indirect -r $sn" ]; then
        test_pass "R2: publish roots generations/<id>/profile-1-link with exactly one nix-store --add-root call"
    else
        test_fail "R2: publish roots generations/<id>/profile-1-link with exactly one nix-store --add-root call (rc $rc; calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"); stderr: $err)"
    fi
    if gc_keeps_via "$sn" "$gen/profile-1-link"; then
        test_pass "R2: after publish a GC keeps the new current generation's profile through its final path"
    else
        test_fail "R2: after publish a GC keeps the new current generation's profile through its final path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if ! gc_has_staging_root && [ ! -e "$stage" ]; then
        test_pass "R2: after publish no live GC root resolves through a .staging- path"
    else
        test_fail "R2: after publish no live GC root resolves through a .staging- path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if generation_intact "$gen" "$sn" && auto_untouched_by_dx_ai; then
        test_pass "R2: the published generation is read-only with an unchanged profile link, and gcroots/auto was edited only by Nix"
    else
        test_fail "R2: the published generation is read-only with an unchanged profile link, and gcroots/auto was edited only by Nix ($(ls -ld "$gen"); auto: $(ls "$NIX_STATE_DIR/gcroots/auto" | tr '\n' ' '))"
    fi
)

(
    w="$fixture/r2-fail"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-a || test_fail "R2 fixture: seed the current generation"
    stage="$(dx_ai_stage_generation "$w/published" "$state" gen-n)"
    dx_ai_install_profile "$stage" >/dev/null
    export FAKE_NIX_STORE_FAIL_MATCH=/generations/gen-n/
    err="$(dx_ai_publish_generation "$state" gen-n "$stage" 2>&1 >/dev/null)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -Fqx 'Error: could not register a GC root for AI generation gen-n' <<<"$err"; then
        test_pass "R2: a publish whose root cannot be registered fails loudly, naming the generation"
    else
        test_fail "R2: a publish whose root cannot be registered fails loudly, naming the generation (rc $rc; stderr: $err)"
    fi
    if [ ! -e "$state/generations/gen-n" ] && [ ! -L "$state/generations/gen-n" ] \
        && [ "$(readlink "$state/current")" = generations/gen-a ]; then
        test_pass "R2: the unrootable generation is removed and current is unchanged"
    else
        test_fail "R2: the unrootable generation is removed and current is unchanged (current -> $(readlink "$state/current"); $(ls -a "$state/generations" | tr '\n' ' '))"
    fi
)

# --- R3/R4/R5 through dx_ai_main ------------------------------------------

# M1: the live incident (current and its predecessor rooted only through
# vanished stages), healed by the next ordinary dx-ai run.
(
    w="$fixture/m1"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-p && seed_incident_generation "$w/published" "$state" gen-a \
        || test_fail "M1 fixture: seed current gen-a with predecessor gen-p"
    sp="$(readlink "$state/generations/gen-p/profile-1-link")"; sa="$(readlink "$state/generations/gen-a/profile-1-link")"
    plant_unrelated_root
    if [ -n "$(sim_gc_roots)" ] || [ "$(cat "$state/generations/gen-a/.predecessor")" != gen-p ]; then
        test_fail "M1 fixture: neither generation has a live root (the incident state)"
    fi
    : > "$FAKE_NIX_LOG"
    main_stubs
    out="$(DX_AI_BOOTSTRAP_ROOT="$w/published" DX_AI_STATE_ROOT="$state" dx_ai_main 2>&1)"; rc=$?
    gen="$state/generations/$new_id"; sn="$(readlink "$gen/profile-1-link" 2>/dev/null)"
    if [ "$rc" -eq 0 ] && [ "$(readlink "$state/current")" = "generations/$new_id" ] && [ -n "$sn" ]; then
        test_pass "M1: dx-ai on an incident-state guest publishes a new generation"
    else
        test_fail "M1: dx-ai on an incident-state guest publishes a new generation (rc $rc; output: $out)"
    fi
    if gc_keeps_via "$sn" "$gen/profile-1-link" && gc_keeps_via "$sa" "$state/generations/gen-a/profile-1-link"; then
        test_pass "M1: a GC then keeps the new current AND the retained predecessor, each through its final path"
    else
        test_fail "M1: a GC then keeps the new current AND the retained predecessor, each through its final path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if ! gc_has_staging_root; then
        test_pass "M1: no live GC root resolves through a .staging- path afterwards"
    else
        test_fail "M1: no live GC root resolves through a .staging- path afterwards (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    expected="nix-store --add-root $state/generations/gen-a/profile-1-link --indirect -r $sa
nix-store --add-root $state/generations/gen-p/profile-1-link --indirect -r $sp
nix profile add --profile $state/generations/.staging-$new_id/profile --extra-experimental-features nix-command flakes --accept-flake-config $state/generations/.staging-$new_id#ai-tools
nix-store --add-root $gen/profile-1-link --indirect -r $sn"
    if [ "$(cat "$FAKE_NIX_LOG")" = "$expected" ]; then
        test_pass "M1: Nix calls are exactly: root current, root its predecessor (no rebuild), build the stage, root the new generation"
    else
        test_fail "M1: Nix calls are exactly: root current, root its predecessor (no rebuild), build the stage, root the new generation (calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"))"
    fi
    if generation_intact "$gen" "$sn" && generation_intact "$state/generations/gen-a" "$sa" && auto_untouched_by_dx_ai; then
        test_pass "M1: both retained generations stay read-only and Nix-shaped, and dx-ai edited gcroots/auto only through Nix"
    else
        test_fail "M1: both retained generations stay read-only and Nix-shaped, and dx-ai edited gcroots/auto only through Nix ($(ls -ld "$gen" "$state/generations/gen-a" 2>&1 | tr '\n' '|'))"
    fi
)

# M2: the same incident state, healed by `dx-ai --recover` without any build.
(
    w="$fixture/m2"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-p && seed_incident_generation "$w/published" "$state" gen-a \
        || test_fail "M2 fixture: seed current gen-a with predecessor gen-p"
    sp="$(readlink "$state/generations/gen-p/profile-1-link")"; sa="$(readlink "$state/generations/gen-a/profile-1-link")"
    plant_unrelated_root
    : > "$FAKE_NIX_LOG"
    main_stubs
    out="$(DX_AI_STATE_ROOT="$state" dx_ai_main --recover 2>&1)"; rc=$?
    if [ "$rc" -eq 0 ] && [ "$(readlink "$state/current")" = generations/gen-p ]; then
        test_pass "M2: dx-ai --recover on an incident-state guest switches current to the predecessor"
    else
        test_fail "M2: dx-ai --recover on an incident-state guest switches current to the predecessor (rc $rc; output: $out)"
    fi
    if gc_keeps_via "$sp" "$state/generations/gen-p/profile-1-link" && gc_keeps_via "$sa" "$state/generations/gen-a/profile-1-link" \
        && ! gc_has_staging_root; then
        test_pass "M2: a GC then keeps both generations through their final paths, none through .staging-"
    else
        test_fail "M2: a GC then keeps both generations through their final paths, none through .staging- (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    expected="nix-store --add-root $state/generations/gen-a/profile-1-link --indirect -r $sa
nix-store --add-root $state/generations/gen-p/profile-1-link --indirect -r $sp"
    if [ "$(cat "$FAKE_NIX_LOG")" = "$expected" ] && auto_untouched_by_dx_ai \
        && generation_intact "$state/generations/gen-a" "$sa" && generation_intact "$state/generations/gen-p" "$sp"; then
        test_pass "M2: --recover heals with exactly two nix-store --add-root calls (current, then predecessor), no build, generations untouched"
    else
        test_fail "M2: --recover heals with exactly two nix-store --add-root calls (current, then predecessor), no build, generations untouched (calls: $(tr '\n' '|' < "$FAKE_NIX_LOG"))"
    fi
)

# M3: the incident's aftermath -- current's profile was already collected.
# Healing cannot root it, says so, and the update still builds a replacement.
(
    w="$fixture/m3"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-p && seed_incident_generation "$w/published" "$state" gen-a \
        || test_fail "M3 fixture: seed current gen-a with predecessor gen-p"
    remove_store_path "$(readlink "$state/generations/gen-a/profile-1-link")"
    main_stubs
    out="$(DX_AI_BOOTSTRAP_ROOT="$w/published" DX_AI_STATE_ROOT="$state" dx_ai_main 2>&1)"; rc=$?
    gen="$state/generations/$new_id"; sn="$(readlink "$gen/profile-1-link" 2>/dev/null)"
    if [ "$rc" -eq 0 ] && grep -Fqx 'Warning: could not register a GC root for AI generation gen-a' <<<"$out" \
        && ! grep -q '^Error:' <<<"$out"; then
        test_pass "M3: a current generation whose store path is gone gets a Warning naming it, and the run still succeeds"
    else
        test_fail "M3: a current generation whose store path is gone gets a Warning naming it, and the run still succeeds (rc $rc; output: $out)"
    fi
    if [ "$(readlink "$state/current")" = "generations/$new_id" ] && gc_keeps_via "$sn" "$gen/profile-1-link"; then
        test_pass "M3: the replacement generation is published and rooted at its final path"
    else
        test_fail "M3: the replacement generation is published and rooted at its final path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
)

# M4: an abandoned stage (a killed run: its live Nix root pins a full
# closure) and an update that then fails before publishing anything.
(
    w="$fixture/m4"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-a || test_fail "M4 fixture: seed current gen-a"
    sa="$(readlink "$state/generations/gen-a/profile-1-link")"
    orphan="$(dx_ai_stage_generation "$w/published" "$state" killed-run)" && dx_ai_install_profile "$orphan" >/dev/null
    if ! gc_has_staging_root; then
        test_fail "M4 fixture: the abandoned stage holds a live GC root"
    fi
    plant_unrelated_root
    main_stubs
    dx_ai_update_flake() { return 1; }
    DX_AI_BOOTSTRAP_ROOT="$w/published" DX_AI_STATE_ROOT="$state" dx_ai_main >/dev/null 2>&1; rc=$?
    if [ "$rc" -ne 0 ] && [ ! -e "$state/generations/.staging-killed-run" ] && ! gc_has_staging_root; then
        test_pass "M4: a failing run still removes an abandoned stage, so no live root pins its closure"
    else
        test_fail "M4: a failing run still removes an abandoned stage, so no live root pins its closure (rc $rc; $(ls -a "$state/generations" | tr '\n' ' '); live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if [ "$(readlink "$state/current")" = generations/gen-a ] && gc_keeps_via "$sa" "$state/generations/gen-a/profile-1-link"; then
        test_pass "M4: the failing run still roots the current generation at its final path"
    else
        test_fail "M4: the failing run still roots the current generation at its final path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
    if auto_untouched_by_dx_ai; then
        test_pass "M4: the abandoned stage's dangling auto link is left for Nix's GC (dx-ai edits gcroots/auto only through Nix)"
    else
        test_fail "M4: the abandoned stage's dangling auto link is left for Nix's GC (dx-ai edits gcroots/auto only through Nix) (auto: $(ls "$NIX_STATE_DIR/gcroots/auto" | tr '\n' ' '))"
    fi
)

# M5: a failed stage -- the build succeeded (Nix rooted the stage) but the
# generation is incomplete, so publish refuses it.
(
    w="$fixture/m5"; world_new "$w/nix"; make_published "$w/published"; state="$w/state"
    seed_incident_generation "$w/published" "$state" gen-a || test_fail "M5 fixture: seed current gen-a"
    sa="$(readlink "$state/generations/gen-a/profile-1-link")"
    main_stubs
    export FAKE_NIX_PROFILE_OMIT=opencode
    out="$(DX_AI_BOOTSTRAP_ROOT="$w/published" DX_AI_STATE_ROOT="$state" dx_ai_main 2>&1)"; rc=$?
    if [ "$rc" -ne 0 ] && grep -Fq 'profile/bin/opencode' <<<"$out" && [ ! -e "$state/generations/.staging-$new_id" ] \
        && ! gc_has_staging_root; then
        test_pass "M5: a refused stage is discarded, and its Nix root no longer pins anything"
    else
        test_fail "M5: a refused stage is discarded, and its Nix root no longer pins anything (rc $rc; live roots: $(sim_gc_roots | tr '\n' '|'); output: $out)"
    fi
    if [ "$(readlink "$state/current")" = generations/gen-a ] && gc_keeps_via "$sa" "$state/generations/gen-a/profile-1-link"; then
        test_pass "M5: the published generation stays current and rooted at its final path"
    else
        test_fail "M5: the published generation stays current and rooted at its final path (live roots: $(sim_gc_roots | tr '\n' '|'))"
    fi
)

# R4: across every run above, dx-ai never collected garbage itself.
if grep -Eh '^(nix-store .*--(gc|delete)|nix-collect-garbage|nix store (gc|delete)|nix-env)' "$fixture"/*/nix/nix.log >/dev/null 2>&1; then
    test_fail "R4: dx-ai never collects garbage or touches nix-env ($(grep -Eh '^(nix-store .*--(gc|delete)|nix-collect-garbage|nix store|nix-env)' "$fixture"/*/nix/nix.log | head -3 | tr '\n' '|'))"
else
    test_pass "R4: dx-ai never collects garbage or touches nix-env"
fi

# --- Real Nix (Linux CI, or any Linux host with Nix) ---------------------
#
# The same publish, against the real boundary: after dx_ai_publish_generation
# the new profile must be alive (`nix-store --delete` refuses it) and
# `--print-roots` must name its final path and no .staging- path. Uses its
# own store paths only; `--delete` removes nothing that is still alive.
real_nix_reason=""
if [ "$(uname -s)" != Linux ]; then
    real_nix_reason="this host is $(uname -s), not Linux"
elif ! PATH="$real_path" command -v nix >/dev/null 2>&1 || ! PATH="$real_path" command -v nix-store >/dev/null 2>&1; then
    real_nix_reason="no nix/nix-store on PATH"
fi
if [ -n "$real_nix_reason" ]; then
    test_skip "real Nix: a published generation is alive through its final-path root ($real_nix_reason; the fake-nix cases above stand in, validated against nixos/nix:2.34.8)"
else
    (
        PATH="$real_path"
        unset NIX_STORE_DIR NIX_STATE_DIR FAKE_NIX_LOG FAKE_NIX_LEDGER
        DX_AI_TOOLS=codex
        w="$fixture/real-nix"; state="$w/state"
        mkdir -p "$w/pkg/ai-tools/bin"
        printf '#!/bin/sh\nexit 0\n' > "$w/pkg/ai-tools/bin/codex"; chmod 0755 "$w/pkg/ai-tools/bin/codex"
        make_published "$w/published"
        if ! tools_path="$(nix-store --add "$w/pkg/ai-tools" 2>/dev/null)" \
            || ! stage="$(dx_ai_stage_generation "$w/published" "$state" real-gen)" \
            || ! { nix --extra-experimental-features nix-command profile add --profile "$stage/profile" "$tools_path" >/dev/null 2>&1 \
                || nix --extra-experimental-features nix-command profile install --profile "$stage/profile" "$tools_path" >/dev/null 2>&1; }; then
            test_fail "real Nix fixture: add a package to the store and build a profile at the stage"
            exit 0
        fi
        s="$(readlink "$stage/profile-1-link")"
        dx_ai_publish_generation "$state" real-gen "$stage" >/dev/null 2>&1; rc=$?
        roots="$(nix-store --gc --print-roots 2>/dev/null)"
        if nix-store --delete "$s" >/dev/null 2>&1; then alive=no; else alive=yes; fi
        if [ "$rc" -eq 0 ] && [ "$alive" = yes ] && "$state/current/profile/bin/codex" \
            && grep -Fq "\"$state/generations/real-gen/profile-1-link\" -> $s" <<<"$roots" \
            && ! grep -Fq "$state/generations/.staging-" <<<"$roots"; then
            test_pass "real Nix: a published generation is alive through its final-path root, and no root names its stage"
        else
            test_fail "real Nix: a published generation is alive through its final-path root, and no root names its stage (publish rc $rc; alive $alive; dx-ai roots: $(grep -F "$state" <<<"$roots" | tr '\n' '|'))"
        fi
    )
fi

# WP1.8: the mv -T shim above must not outlive this file.
unset -f mv

print_summary
exit_with_code
