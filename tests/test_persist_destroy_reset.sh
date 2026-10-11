#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP5.1 (plans/do D-7; spec R25, R26): destroy and reset in host-path mode.
#
# Interface contract (pinned by this file; the implementation must match):
#   Scope: DX_RUNTIME=docker-ssh with DX_PERSIST_STORAGE=host-path. Volume mode
#   (docker-ssh and Apple) behaves byte-for-byte as before: the golden
#   transcripts under tests/fixtures/persist-destroy-reset/ were captured from
#   the tree before this work package and must keep matching. Apple refuses
#   host-path in configuration, so only its volume mode exists.
#
#   bin/dx-destroy-volumes --force and bin/dx-factory-reset --force (the
#   non-interactive form; the typed confirmation needs a tty and is not
#   driven here), in host-path mode:
#     * Delete the nix and bootstrap volumes only, in that order (exactly one
#       `volume rm` argv word each). NEVER a `volume rm` of a persist volume:
#       neither the configured DX_PERSIST_VOLUME nor the marker's
#       source-volume. No remote rm/rmdir/mv/chmod/chown/find/rsync under the
#       share root, and the directory tree, its marker and the D-7 record file
#       are left exactly as they were.
#     * The ownership proof (dx_destructive_plan_and_verify) lists only nix
#       and bootstrap volumes (`  volume NAME: ...` plan lines): a persist
#       volume is neither listed nor label-checked, so a mislabelled persist
#       volume does not refuse the destroy. factory-reset's plan also lists
#       the container, as today.
#     * They print, once per run (a factory reset prints them once, not once
#       per command), these whole lines on stdout (stderr is also accepted by
#       the test, which merges both streams). <ROOT> is DX_PERSIST_HOST_ROOT
#       exactly as configured (not canonicalised), <GUEST> is
#       DX_CONTAINER_NAME, <PROFILE> is `$DX_REMOTE_HOST__$DX_CONTAINER_NAME`
#       (dx_runtime_docker_profile_id, the DQ6 label value), <STATE> is
#       ${XDG_STATE_HOME:-$HOME/.local/state}:
#         Kept /persist host directory: <ROOT>/dxe/<GUEST>/persist
#           manual removal 1: with the guest stopped, remove <ROOT>/dxe/<GUEST> on the NAS
#           manual removal 2: delete the record file <STATE>/dxe/persist-dirs/<PROFILE>
#       and then, for each persist volume that still EXISTS (the configured
#       DX_PERSIST_VOLUME first, then the marker's source-volume when present
#       and different; listed once if they are the same; nothing for one that
#       does not exist), two lines:
#         Kept persist volume: <NAME>
#           delete with: docker volume rm <NAME>
#       The directory lines are printed even when the directory is absent or
#       the marker cannot be read (the probe is read-only: facts only,
#       dx_runtime_host_dir_probe ROOT GUEST; a failed or marker-less probe
#       simply contributes no source-volume). The command still succeeds.
#   bin/dx-status, in host-path mode, adds to the `--- /persist storage ---`
#   section one line per existing kept persist volume, in the same order:
#         kept volume: <NAME>
#   Volume mode adds no such line and no marker probe.
#
# All "remote" commands run in the NAS fake with DXE_FAKE_SSH_REMOTE_PATH
# pinned to a directory of recording stubs for every destructive command, so
# a regression can do no real damage; nothing here reaches a real runtime.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$BASE_DIR/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"

test_section "WP5.1: destroy and reset keep the host directory and persist volumes"

GOLDEN_DIR="$SCRIPT_DIR/fixtures/persist-destroy-reset"
fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-destroy.XXXXXX")"
trap 'persist_fixture_cleanup "$fixture"' EXIT
mkdir -p "$fixture/home/keys" "$fixture/state"
PROFILE=dxe-fixture-nas.invalid__dx-hp
RECORD="$fixture/state/dxe/persist-dirs/$PROFILE"

# The destructive commands the remote shell must never run, as recording stubs.
STUB_NAMES="rm rmdir mv chmod chown find rsync unlink ln"

# --- scenario construction ---------------------------------------------------
# new_case ROOTKIND: builds a fresh share root, tool dirs, docker fake and
# state. Sets ROOT TOOLS RBIN DLOG RMLOG DESTLOG VOLS SSHLOG.
new_case() {
    local tool real
    ROOT="$(persist_fixture_root_create "$fixture")"
    TOOLS="$(persist_fixture_nas_create "$ROOT" "$fixture")"
    RBIN="$(mktemp -d "$fixture/dxe-remote-bin.XXXXXX")"
    DLOG="$RBIN/docker.log"; RMLOG="$RBIN/volume-rm.log"; DESTLOG="$RBIN/destructive.log"
    SSHLOG="$RBIN/ssh.log"; VOLS="$RBIN/vols"
    mkdir -p "$VOLS"
    : > "$DLOG"; : > "$RMLOG"; : > "$DESTLOG"; : > "$SSHLOG"
    for tool in sh ls cat awk cut head tail tr du dirname env; do
        real="$(command -v "$tool")" && ln -sf "$real" "$RBIN/$tool"
    done
    for tool in $STUB_NAMES; do
        fake_tool_write "$RBIN" "$tool" "printf '%s %s\\n' '$tool' \"\$*\" >> '$DESTLOG'; exit 0"
    done
    fake_tool_write "$RBIN" docker "printf '%s\\n' \"\$*\" >> '$DLOG'
case \"\$1 \$2\" in
    'version --format') echo 27.3.1; exit 0 ;;
    'info --format') echo 'abc123def|qnap-fake|x86_64|linux'; exit 0 ;;
    'container inspect') exit 1 ;;
    'image inspect') exit 1 ;;
    'volume inspect')
        name=\"\$(for a in \"\$@\"; do :; done; echo \"\$a\")\"
        if [ -f '$VOLS'/\"\$name\" ]; then cat '$VOLS'/\"\$name\"; exit 0; fi
        echo \"Error: No such volume: \$name\" >&2; exit 1 ;;
    'volume rm') shift 2; printf '%s\\n' \"\$@\" >> '$RMLOG'; exit 0 ;;
esac
echo \"UNMATCHED: \$*\" >&2; exit 99"
    fake_tool_write "$TOOLS" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_tool_write "$RBIN" uname 'case "$1" in -m) echo x86_64 ;; esac'
    rm -rf "$fixture/state/dxe"
    printf 'dx_key\n' > "$fixture/home/keys/dx_key"
    printf 'dx_key.pub\n' > "$fixture/home/keys/dx_key.pub"
}

# vol NAME ROLE|bad: the volume exists in the docker fake, correctly labelled
# for ROLE, or unlabelled (a collision) for `bad`.
vol() {
    if [ "$2" = bad ]; then
        printf '<no value>|<no value>|<no value>|<no value>|<no value>\n' > "$VOLS/$1"
    else
        printf 'true|1|dxe-fixture-nas.invalid__dx-hp|%s|x86_64-linux\n' "$2" > "$VOLS/$1"
    fi
}

# make_dir [SOURCE_VOLUME]: the guest directory with a ready marker and data.
make_dir() {
    mkdir -p "$ROOT/dxe/dx-hp/persist"
    dx_persist_marker_format dx-hp ready "${1:-}" 2025-01-02T03:04:05Z > "$ROOT/dxe/dx-hp/persist/.dxe-persist-dir"
    printf 'user work\n' > "$ROOT/dxe/dx-hp/persist/work.txt"
}

make_record() {
    mkdir -p "$fixture/state/dxe/persist-dirs"
    printf 'record\n' > "$RECORD"
}

# run_dx MODE CMD [ARGS...]: MODE host-path|volume|apple. Sets OUT and RC.
run_dx() {
    local mode="$1" cmd="$2"; shift 2
    local storage=()
    case "$mode" in
        host-path) storage=(DX_PERSIST_STORAGE=host-path "DX_PERSIST_HOST_ROOT=$ROOT") ;;
        *) : ;;
    esac
    OUT="$(env -i HOME="$fixture/home" XDG_STATE_HOME="$fixture/state" TMPDIR="$fixture" \
        PATH="$TOOLS:/usr/bin:/bin" \
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux \
        DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-hp DX_IMAGE=dx-hp-nixos \
        DX_NIX_VOLUME=dx-hp-nix DX_PERSIST_VOLUME=dx-hp-persist DX_BOOTSTRAP_VOLUME=dx-hp-bootstrap \
        DX_SSH_KEY="$fixture/home/keys/dx_key" \
        DXE_FAKE_SSH_REMOTE_PATH="$RBIN" DXE_FAKE_SSH_ARGV_LOG="$SSHLOG" \
        "${storage[@]+"${storage[@]}"}" \
        "$BASE_DIR/bin/$cmd" "$@" < /dev/null 2>&1)"
    RC=$?
}

has_line() { grep -Fqx -- "$2" <<<"$1"; }
count_line() { grep -Fxc -- "$2" <<<"$1"; }
tree_sig() { persist_fixture_tree_list "$ROOT" | tr '\0' '\n' | cksum; }

# --- golden transcripts (volume mode) ----------------------------------------
normalise() { # stdin -> stdout, fixture path hidden
    local phys
    phys="$(cd -P -- "$fixture" && pwd)"
    perl -pe 'BEGIN { $f = shift; $p = shift } s/\Q$p\E/<FIX>/g; s/\Q$f\E/<FIX>/g' "$fixture" "$phys"
}
transcript() { # cmd: RC, output, docker calls, volume rm calls
    {
        printf 'rc=%s\n--- output ---\n%s\n--- docker ---\n%s\n--- volume rm ---\n%s\n' \
            "$RC" "$OUT" "$(cat "$DLOG")" "$(cat "$RMLOG")"
    } | normalise
}
check_golden() { # name label
    local golden="$GOLDEN_DIR/$1.txt" got
    got="$(transcript)"
    if [ -n "${PERSIST_DR_CAPTURE_DIR:-}" ]; then
        printf '%s\n' "$got" > "$PERSIST_DR_CAPTURE_DIR/$1.txt"
        return 0
    fi
    if [ -f "$golden" ] && [ "$got" = "$(cat "$golden")" ]; then
        test_pass "$2"
    else test_fail "$2 (transcript differs from $golden): $got"; fi
}

# 1. volume mode, docker-ssh: all three volumes present and labelled.
new_case; vol dx-hp-nix nix; vol dx-hp-persist persist; vol dx-hp-bootstrap bootstrap
run_dx volume dx-destroy-volumes --force
check_golden volume-destroy-volumes "volume mode: dx-destroy-volumes --force transcript is today's"
if ! grep -Fq .dxe-persist-dir "$SSHLOG" && [ ! -s "$DESTLOG" ]; then
    test_pass "volume mode: no directory probe and no remote destructive command"
else test_fail "volume mode: no directory probe and no remote destructive command"; fi

new_case; vol dx-hp-nix nix; vol dx-hp-persist persist; vol dx-hp-bootstrap bootstrap
run_dx volume dx-factory-reset --force
check_golden volume-factory-reset "volume mode: dx-factory-reset --force transcript is today's"
if [ ! -e "$fixture/home/keys/dx_key" ]; then test_pass "volume mode: factory reset still removes the key pair"
else test_fail "volume mode: factory reset still removes the key pair"; fi

new_case
run_dx volume dx-destroy-volumes --force
check_golden volume-destroy-none "volume mode: nothing to destroy transcript is today's"

new_case; vol dx-hp-nix nix; vol dx-hp-persist persist; vol dx-hp-bootstrap bootstrap
run_dx volume dx-destroy-volumes
check_golden volume-destroy-noforce "volume mode: refusal without --force and without a tty is today's"

# 2. Apple runtime: host-path is refused by configuration, volume mode only.
new_case
fake_tool_write "$TOOLS" container "printf '%s\\n' \"\$*\" >> '$DLOG'
case \"\$1 \$2\" in
    'volume inspect') [ -f '$VOLS'/\"\$3\" ] && exit 0; exit 1 ;;
    'volume rm') shift 2; printf '%s\\n' \"\$@\" >> '$RMLOG'; exit 0 ;;
    'system status') exit 0 ;;
esac
exit 1"
for v in dx-hp-nix dx-hp-persist dx-hp-bootstrap; do : > "$VOLS/$v"; done
apple_run() { # args...: env for the Apple runtime
    OUT="$(env -i HOME="$fixture/home" XDG_STATE_HOME="$fixture/state" TMPDIR="$fixture" \
        PATH="$TOOLS:/usr/bin:/bin" DX_RUNTIME=apple DX_CONTAINER_NAME=dx-hp DX_IMAGE=dx-hp-nixos \
        DX_NIX_VOLUME=dx-hp-nix DX_PERSIST_VOLUME=dx-hp-persist DX_BOOTSTRAP_VOLUME=dx-hp-bootstrap \
        "$@" 2>&1 < /dev/null)"
    RC=$?
}
apple_run "$BASE_DIR/bin/dx-destroy-volumes" --force
check_golden apple-destroy-volumes "apple: dx-destroy-volumes --force transcript is today's (all three volumes removed)"

new_case
fake_tool_write "$TOOLS" container "printf '%s\\n' \"\$*\" >> '$DLOG'; exit 1"
apple_run DX_PERSIST_STORAGE=host-path DX_PERSIST_HOST_ROOT=/fixture-root "$BASE_DIR/bin/dx-destroy-volumes" --force
if [ "$RC" -ne 0 ] && grep -Fq 'requires DX_RUNTIME=docker-ssh' <<<"$OUT" && [ ! -s "$RMLOG" ]; then
    test_pass "apple: host-path is refused by configuration and nothing is deleted"
else test_fail "apple: host-path is refused by configuration and nothing is deleted (rc=$RC out: $OUT)"; fi

# 3. host-path mode.
check_kept() { # label out [volumes...]: the whole-line output contract
    local label="$1" out="$2" want_dir want_rec
    want_dir="$ROOT/dxe/dx-hp/persist"
    want_rec="$fixture/state/dxe/persist-dirs/$PROFILE"
    if has_line "$out" "Kept /persist host directory: $want_dir" \
        && has_line "$out" "  manual removal 1: with the guest stopped, remove $ROOT/dxe/dx-hp on the NAS" \
        && has_line "$out" "  manual removal 2: delete the record file $want_rec"; then
        test_pass "$label: prints the kept directory and both manual removal steps"
    else test_fail "$label: prints the kept directory and both manual removal steps (out: $out)"; fi
}
check_kept_vols() { # label out expected-names...
    local label="$1" out="$2" ok=1 n=0 name
    shift 2
    for name in "$@"; do
        has_line "$out" "Kept persist volume: $name" || ok=0
        has_line "$out" "  delete with: docker volume rm $name" || ok=0
        n=$((n + 1))
    done
    [ "$(grep -Fc 'Kept persist volume: ' <<<"$out")" -eq "$n" ] || ok=0
    [ "$(grep -Fc 'docker volume rm ' <<<"$out")" -eq "$n" ] || ok=0
    if [ "$ok" -eq 1 ]; then test_pass "$label: lists exactly the kept volumes ($*) with their delete commands"
    else test_fail "$label: lists exactly the kept volumes ($*) (out: $out)"; fi
}
check_untouched() { # label sig-before
    local label="$1"
    if [ "$(tree_sig)" = "$2" ] && [ -f "$ROOT/dxe/dx-hp/persist/work.txt" ] && [ -f "$ROOT/dxe/dx-hp/persist/.dxe-persist-dir" ] \
        && [ ! -s "$DESTLOG" ] && [ "$(cat "$RECORD" 2>/dev/null)" = record ]; then
        test_pass "$label: directory, marker and record file untouched; no remote destructive command"
    else test_fail "$label: directory, marker and record file untouched (destructive: $(cat "$DESTLOG"))"; fi
}
check_plan() { # label out with-container(0|1) volume-lines (2 per plan printed)
    local out="$2" ok=1
    [ "$(grep -Fc 'Immutable plan (docker-ssh ownership proof' <<<"$out")" -ge 1 ] || ok=0
    grep -Eq '^  volume dx-hp-nix: labels=' <<<"$out" || ok=0
    grep -Eq '^  volume dx-hp-bootstrap: labels=' <<<"$out" || ok=0
    ! grep -Eq '^  volume dx-hp-(persist|old)[:]' <<<"$out" || ok=0
    [ "$(grep -Ec '^  volume ' <<<"$out")" -eq "$4" ] || ok=0
    if [ "$3" = 1 ]; then grep -Eq '^  container dx-hp: ' <<<"$out" || ok=0; fi
    if [ "$ok" -eq 1 ]; then test_pass "$1: the ownership plan lists only the nix and bootstrap volumes"
    else test_fail "$1: the ownership plan lists only the nix and bootstrap volumes (out: $out)"; fi
}
check_rm() { # label
    if [ "$(cat "$RMLOG")" = "$(printf 'dx-hp-nix\ndx-hp-bootstrap')" ]; then
        test_pass "$1: volume rm for nix then bootstrap only; no persist volume removed"
    else test_fail "$1: volume rm for nix then bootstrap only (got: $(cat "$RMLOG"))"; fi
}

for cmd in dx-destroy-volumes dx-factory-reset; do
    # a. directory with a marker naming a source volume; both persist volumes exist
    new_case; make_dir dx-hp-old; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist; vol dx-hp-old persist
    sig="$(tree_sig)"
    run_dx host-path "$cmd" --force
    L="host-path $cmd"
    if [ "$RC" -eq 0 ]; then test_pass "$L: succeeds"; else test_fail "$L: succeeds (rc=$RC out: $OUT)"; fi
    check_rm "$L"
    check_untouched "$L" "$sig"
    check_kept "$L" "$OUT"
    check_kept_vols "$L" "$OUT" dx-hp-persist dx-hp-old
    if [ "$cmd" = dx-factory-reset ]; then check_plan "$L" "$OUT" 1 4; else check_plan "$L" "$OUT" 0 2; fi
    if [ "$(count_line "$OUT" "Kept /persist host directory: $ROOT/dxe/dx-hp/persist")" -eq 1 ]; then
        test_pass "$L: the kept lines are printed once"
    else test_fail "$L: the kept lines are printed once (out: $OUT)"; fi
    if ! grep -Fq 'Removing volume dx-hp-persist' <<<"$OUT" && ! grep -Fq 'Removing volume dx-hp-old' <<<"$OUT"; then
        test_pass "$L: never announces removing a persist volume"
    else test_fail "$L: never announces removing a persist volume (out: $OUT)"; fi
    if grep -Fq 'volume rm' "$DLOG" && ! grep -F 'volume rm' "$DLOG" | grep -Fq -e dx-hp-persist -e dx-hp-old; then
        test_pass "$L: no docker volume rm names a persist volume"
    else test_fail "$L: no docker volume rm names a persist volume (docker: $(cat "$DLOG"))"; fi
    if [ "$cmd" = dx-factory-reset ]; then
        if has_line "$OUT" "Factory reset complete." && [ ! -e "$fixture/home/keys/dx_key" ]; then
            test_pass "$L: still completes and removes the key pair"
        else test_fail "$L: still completes and removes the key pair (out: $OUT)"; fi
    fi

    # b. mislabelled persist volumes are not part of the ownership proof
    new_case; make_dir dx-hp-old; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist bad; vol dx-hp-old bad
    sig="$(tree_sig)"
    run_dx host-path "$cmd" --force
    if [ "$RC" -eq 0 ] && ! grep -Fq 'collision' <<<"$OUT"; then
        test_pass "$L: a mislabelled persist volume does not refuse the run"
    else test_fail "$L: a mislabelled persist volume does not refuse the run (rc=$RC out: $OUT)"; fi
    check_rm "$L (mislabelled persist)"
    check_untouched "$L (mislabelled persist)" "$sig"
    check_kept_vols "$L (mislabelled persist)" "$OUT" dx-hp-persist dx-hp-old

    # c. a mislabelled nix volume still refuses the whole run, nothing removed
    new_case; make_dir; make_record
    vol dx-hp-nix bad; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist
    run_dx host-path "$cmd" --force
    if [ "$RC" -ne 0 ] && [ ! -s "$RMLOG" ] && grep -Fq 'collision, not an adoption candidate' <<<"$OUT"; then
        test_pass "$L: a mislabelled nix volume still refuses the whole run"
    else test_fail "$L: a mislabelled nix volume still refuses the whole run (rc=$RC out: $OUT)"; fi

    # d. only the configured volume exists, marker names no source volume
    new_case; make_dir; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist
    run_dx host-path "$cmd" --force
    check_kept_vols "$L (no source-volume)" "$OUT" dx-hp-persist

    # e. marker source-volume equals the configured one: listed once
    new_case; make_dir dx-hp-persist; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist
    run_dx host-path "$cmd" --force
    check_kept_vols "$L (source = configured)" "$OUT" dx-hp-persist

    # f. only the marker's volume exists
    new_case; make_dir dx-hp-old; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-old persist
    run_dx host-path "$cmd" --force
    check_kept_vols "$L (only the source volume exists)" "$OUT" dx-hp-old

    # g. no persist volume exists at all: the directory is still reported
    new_case; make_dir dx-hp-old; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap
    run_dx host-path "$cmd" --force
    check_kept "$L (no persist volumes)" "$OUT"
    check_kept_vols "$L (no persist volumes)" "$OUT"
    check_rm "$L (no persist volumes)"

    # h. the directory is absent: reported all the same, still succeeds
    new_case; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist
    run_dx host-path "$cmd" --force
    if [ "$RC" -eq 0 ]; then test_pass "$L (directory absent): succeeds"; else test_fail "$L (directory absent): succeeds (rc=$RC out: $OUT)"; fi
    check_kept "$L (directory absent)" "$OUT"
    check_kept_vols "$L (directory absent)" "$OUT" dx-hp-persist
    check_rm "$L (directory absent)"
    if [ ! -s "$DESTLOG" ] && [ "$(cat "$RECORD")" = record ] && [ ! -e "$ROOT/dxe" ]; then
        test_pass "$L (directory absent): creates and deletes nothing"
    else test_fail "$L (directory absent): creates and deletes nothing"; fi

    # i. the share root cannot be read: still succeeds, still reports
    new_case; make_dir dx-hp-old; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist; vol dx-hp-old persist
    ROOT_SAVED="$ROOT"; ROOT="$ROOT/no-such-root"
    run_dx host-path "$cmd" --force
    ROOT="$ROOT_SAVED"
    if [ "$RC" -eq 0 ] && grep -Fq 'Kept /persist host directory: ' <<<"$OUT" && has_line "$OUT" 'Kept persist volume: dx-hp-persist' \
        && ! grep -Fq 'Kept persist volume: dx-hp-old' <<<"$OUT"; then
        test_pass "$L (unreadable root): succeeds and reports the configured volume only"
    else test_fail "$L (unreadable root): succeeds and reports the configured volume only (rc=$RC out: $OUT)"; fi
    check_rm "$L (unreadable root)"
done

# j. refusal without --force and without a tty: nothing removed, plan is nix/bootstrap only
new_case; make_dir dx-hp-old; make_record
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist; vol dx-hp-old persist
run_dx host-path dx-destroy-volumes
if [ "$RC" -ne 0 ] && [ ! -s "$RMLOG" ] && grep -Fq 'without --force' <<<"$OUT"; then
    test_pass "host-path dx-destroy-volumes without --force and without a tty refuses and removes nothing"
else test_fail "host-path dx-destroy-volumes without --force refuses (rc=$RC out: $OUT)"; fi
check_plan "host-path dx-destroy-volumes (no --force)" "$OUT" 0 2

# k. the record location falls back to $HOME/.local/state when XDG_STATE_HOME is unset
new_case; make_dir; mkdir -p "$fixture/home/.local/state/dxe/persist-dirs"
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap
OUT="$(env -i HOME="$fixture/home" TMPDIR="$fixture" PATH="$TOOLS:/usr/bin:/bin" \
    DX_RUNTIME=docker-ssh DX_REMOTE_HOST=dxe-fixture-nas.invalid DX_GUEST_SYSTEM=x86_64-linux \
    DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-hp DX_IMAGE=dx-hp-nixos \
    DX_NIX_VOLUME=dx-hp-nix DX_PERSIST_VOLUME=dx-hp-persist DX_BOOTSTRAP_VOLUME=dx-hp-bootstrap \
    DX_PERSIST_STORAGE=host-path "DX_PERSIST_HOST_ROOT=$ROOT" \
    DXE_FAKE_SSH_REMOTE_PATH="$RBIN" DXE_FAKE_SSH_ARGV_LOG="$SSHLOG" \
    "$BASE_DIR/bin/dx-destroy-volumes" --force < /dev/null 2>&1)"
RC=$?
if [ "$RC" -eq 0 ] && has_line "$OUT" "  manual removal 2: delete the record file $fixture/home/.local/state/dxe/persist-dirs/$PROFILE"; then
    test_pass "record path falls back to \$HOME/.local/state/dxe/persist-dirs/<profile id>"
else test_fail "record path falls back to \$HOME/.local/state (rc=$RC out: $OUT)"; fi

# --- dx-status ---------------------------------------------------------------
section_of() { awk '/^--- \/persist storage ---$/ { on = 1; next } /^--- / { on = 0 } on' <<<"$1"; }

new_case; make_dir dx-hp-old; make_record
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist; vol dx-hp-old persist
run_dx host-path dx-status
sec="$(section_of "$OUT")"
want="$(printf 'kept volume: dx-hp-persist\nkept volume: dx-hp-old')"
if [ "$RC" -eq 0 ] && [ "$(grep -F 'kept volume: ' <<<"$sec")" = "$want" ] && has_line "$sec" "configured: $ROOT/dxe/dx-hp/persist"; then
    test_pass "status: host-path mode lists the kept volumes in the /persist storage section"
else test_fail "status: host-path mode lists the kept volumes (rc=$RC section: $sec)"; fi
if ! grep -Fq 'kept volume: ' <<<"$(printf '%s\n' "$OUT" | awk '/^--- \/persist storage ---$/ { on = 0; next } /^--- / { on = 1 } on')"; then
    test_pass "status: kept volumes appear only in the /persist storage section"
else test_fail "status: kept volumes appear only in the /persist storage section"; fi
if [ ! -s "$DESTLOG" ] && ! grep -Fq 'volume rm' "$DLOG"; then test_pass "status: deletes nothing"
else test_fail "status: deletes nothing"; fi

new_case; make_dir dx-hp-old; make_record
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist
run_dx host-path dx-status
sec="$(section_of "$OUT")"
if [ "$(grep -F 'kept volume: ' <<<"$sec")" = 'kept volume: dx-hp-persist' ]; then
    test_pass "status: a kept volume that does not exist is not listed"
else test_fail "status: a kept volume that does not exist is not listed (section: $sec)"; fi

new_case; make_dir dx-hp-old; make_record
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap
run_dx host-path dx-status
sec="$(section_of "$OUT")"
if [ "$RC" -eq 0 ] && ! grep -Fq 'kept volume: ' <<<"$sec" && [ -n "$sec" ]; then
    test_pass "status: no kept volume line when no persist volume exists"
else test_fail "status: no kept volume line when no persist volume exists (section: $sec)"; fi

new_case; make_dir dx-hp-old
vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap; vol dx-hp-persist persist; vol dx-hp-old persist
run_dx volume dx-status
sec="$(section_of "$OUT")"
if [ "$RC" -eq 0 ] && ! grep -Fq 'kept volume: ' <<<"$sec" && has_line "$sec" 'configured: dx-hp-persist' \
    && ! grep -Fq .dxe-persist-dir "$SSHLOG"; then
    test_pass "status: volume mode adds no kept volume line and makes no directory probe"
else test_fail "status: volume mode adds no kept volume line (rc=$RC section: $sec)"; fi

print_summary
exit_with_code
