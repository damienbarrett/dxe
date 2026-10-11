#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
# WP5.3 (plans/do D-7, D-9; spec R27, R28): reuse of the /persist host
# directory after a factory reset. Pure composition proof: it adds no
# behaviour of its own; it runs, on fakes, the real `bin/dx-factory-reset
# --force` and then the real bring-up children in the order bin/dx runs them
# (dx_connect_or_bring_up: dx-create-keys, dx-create-image, dx-create-volumes,
# dx-create-container, dx-start-container, dx-wait-ssh) and pins what WP4.3
# (start decision) and WP5.1 (destroy/reset keep the directory and volumes)
# must add up to.
#
# Interface contract (pinned by this file; no new production names):
#   Scope: DX_RUNTIME=docker-ssh, DX_PERSIST_STORAGE=host-path, guest dx-hp,
#   profile id dxe-fixture-nas.invalid__dx-hp. Only existing names are used:
#   dx-factory-reset, dx-create-image, dx-create-volumes, dx-create-container,
#   dx-start-container, the D-7 record at
#   ${XDG_STATE_HOME}/dxe/persist-dirs/<profile id>, and the D-9 refusal
#   wording WP4.3 pins (one `Error:` line on stderr, none on stdout, naming
#   the missing directory, the record path when the record exists and
#   dx-persist-migrate when the persist volume exists).
#
#   Reuse (the directory holds a `ready` marker naming the guest, the D-7
#   record exists; the persist volume is either absent -- a guest that was
#   host-path from the start -- or kept from an earlier volume-mode life):
#     * dx-factory-reset --force succeeds; it removes the nix and bootstrap
#       volumes, never a persist volume, and the share, the marker, the user's
#       files (symlinks into /nix/store included, left exactly as they were:
#       not deleted, not rewritten, not followed) and the record are
#       byte-identical afterwards.
#     * the bring-up that follows (create-image, create-volumes,
#       create-container, start-container) succeeds with no `Error:` line
#       anywhere. It creates only the nix and bootstrap volumes (never a
#       persist volume), sends nothing destructive or creating to the NAS
#       shell (no mkdir, mv, rm, chmod, chown, find, rsync, mktemp: all
#       recorded by stubs), and the share is still byte-identical: no
#       directory is created and nothing is established or written.
#       dx-create-container's single `--mount` is
#       type=bind,source=<root>/dxe/dx-hp/persist,target=/persist, i.e. the
#       existing ready directory, and the container is then started.
#     * the persist volume(s) that existed before still exist, with their
#       original metadata, and no `volume rm` or `volume create` ever names
#       one.
#   Refusal (the directory is gone -- someone deleted it on the shared
#   share -- but the D-7 record is present; and separately, no record but the
#   persist volume exists): the reset still succeeds and still prints the kept
#   directory; the bring-up stops at dx-create-volumes with a non-zero status
#   and exactly one `Error:` line (stderr only) carrying the recovery
#   instructions: the directory path, the record path when the record exists
#   and dx-persist-migrate when a persist volume exists. Before that point
#   nothing was created: no volume create, no `docker create`, no start, no
#   mkdir, and the share is byte-identical (still without the directory).
#   The bring-up chain stops there, as bin/dx's loop does on a failing child.
#
#   R28 (tool state in /persist pointing into the deleted /nix store recovers
#   on the next boot) is only partly testable on fakes. Pinned here: the
#   reset deletes and rewrites nothing of the kept /persist content, so that
#   state is still there to recover (symlink targets compared by readlink
#   before and after). LIVE-ONLY, not provable on fakes: that the guest, on
#   its next boot with a fresh /nix, actually repairs those links (the
#   behaviour dx-reset-nix-volume already relies on). The WP7.1 live run on
#   the disposable QNAP guest validates it.
#
#   dx-create-keys and dx-wait-ssh are not run: the first needs a real
#   ssh-keygen (absent in the coverage container) and neither touches
#   /persist; the key pair is staged by the test as a reset-then-regenerate.
#
# Every "remote" command runs in the NAS fake with DXE_FAKE_SSH_REMOTE_PATH
# pinned to a directory of recording stubs for every destructive or creating
# command, so a regression can do no real damage; nothing reaches a real
# runtime. A scratch copy of bin/ with dx-sync-bootstrap replaced by a stub
# runs the children (that script talks to a live guest).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
source "$SCRIPT_DIR/lib/fake-tools.sh"
source "$SCRIPT_DIR/lib/persist-fixtures.sh"
# shellcheck source=../container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh
source "$BASE_DIR/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"

test_section "WP5.3: reuse of the host directory after a factory reset"

fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-persist-reuse.XXXXXX")"
trap 'persist_fixture_cleanup "$fixture"' EXIT
NAS="$PERSIST_FIXTURE_NAS_HOST"
PROFILE="${NAS}__dx-hp"
ADDR="$(printf '%s.%s.%s.%s' 100 64 1 2)"

# A scratch copy of the entry points; only dx-sync-bootstrap differs.
mkdir -p "$fixture/repo"
SBIN="$fixture/repo/bin"
cp -R "$BASE_DIR/bin" "$SBIN"
for d in container docs; do [ ! -e "$BASE_DIR/$d" ] || ln -s "$BASE_DIR/$d" "$fixture/repo/$d"; done
rm -f "$SBIN/dx-sync-bootstrap"
fake_tool_write "$SBIN" dx-sync-bootstrap 'if [ "${1:-}" = --result-file ]; then printf "outcome=unchanged\ngeneration=g1\n" > "$2"; fi
exit 0'

# The commands the remote shell must never run, as recording stubs.
STUB_NAMES="rm rmdir mv chmod chown find rsync unlink ln mkdir mktemp touch cp tee dd install"

# new_world: a fresh share root, NAS fake and docker fake with volume state.
# Sets ROOT TOOLS RBIN DLOG RMLOG CRLOG ARGV DESTLOG VOLS STATE.
new_world() {
    local tool real
    ROOT="$(persist_fixture_root_create "$fixture")"
    TOOLS="$(persist_fixture_nas_create "$ROOT" "$fixture")"
    RBIN="$(mktemp -d "$fixture/dxe-remote-bin.XXXXXX")"
    DLOG="$RBIN/docker.log"; RMLOG="$RBIN/volume-rm.log"; CRLOG="$RBIN/volume-create.log"
    ARGV="$RBIN/create-argv.log"; DESTLOG="$RBIN/destructive.log"
    VOLS="$RBIN/vols"; STATE="$RBIN/state"
    mkdir -p "$VOLS" "$STATE" "$RBIN/home/keys"
    : > "$DLOG"; : > "$RMLOG"; : > "$CRLOG"; : > "$ARGV"; : > "$DESTLOG"
    for tool in sh ls cat awk cut head tail tr du dirname env; do
        real="$(command -v "$tool")" && ln -sf "$real" "$RBIN/$tool"
    done
    for tool in $STUB_NAMES; do
        fake_tool_write "$RBIN" "$tool" "printf '%s %s\\n' '$tool' \"\$*\" >> '$DESTLOG'; exit 0"
    done
    fake_tool_write "$RBIN" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_tool_write "$TOOLS" uname 'case "$1" in -m) echo x86_64 ;; esac'
    fake_tool_write "$RBIN" tailscale "case \"\$*\" in
    \"ip -4\") printf '%s\\n' '$ADDR' ;;
    *) echo \"UNMATCHED: \$*\" >&2; exit 99 ;;
esac"
    fake_tool_write "$RBIN" docker "printf '%s\\n' \"\$*\" >> '$DLOG'
last=''
for a in \"\$@\"; do last=\"\$a\"; done
case \"\$1 \$2\" in
    'version --format') echo 27.3.1; exit 0 ;;
    'info --format') echo 'abc123def|qnap-fake|x86_64|linux'; exit 0 ;;
    'image inspect') [ -f '$STATE/image' ] && { echo sha256:cafe; exit 0; }; exit 1 ;;
    'image rm') /bin/rm -f '$STATE/image'; exit 0 ;;
    'pull '*) exit 0 ;;
    'tag '*) : > '$STATE/image'; exit 0 ;;
    'volume inspect')
        if [ -f '$VOLS'/\"\$last\" ]; then
            if [ \"\$3\" = --format ]; then cat '$VOLS'/\"\$last\"; else echo '[{}]'; fi
            exit 0
        fi
        echo \"Error: No such volume: \$last\" >&2; exit 1 ;;
    'volume create')
        printf '%s\\n' \"\$last\" >> '$CRLOG'
        case \"\$last\" in
            *-nix) role=nix ;; *-persist) role=persist ;; *) role=bootstrap ;;
        esac
        printf 'true|1|$PROFILE|%s|x86_64-linux\\n' \"\$role\" > '$VOLS'/\"\$last\"
        echo \"\$last\"; exit 0 ;;
    'volume rm') shift 2; printf '%s\\n' \"\$@\" >> '$RMLOG'; for v in \"\$@\"; do /bin/rm -f '$VOLS'/\"\$v\"; done; exit 0 ;;
    'container inspect')
        case \"\$*\" in
            *dxe-lock-*) echo 'true|$PROFILE|lock|'\"\$DXE_LIFECYCLE_LOCK_OWNER\"; exit 0 ;;
        esac
        [ -f '$STATE/container' ] || exit 1
        case \"\$*\" in
            *State.Running*) if [ -f '$STATE/running' ]; then echo true; else echo false; fi; exit 0 ;;
            *RestartCount*) echo 0; exit 0 ;;
            *io.dxe.managed*) echo 'true|1|$PROFILE|container|x86_64-linux'; exit 0 ;;
            *.Mounts*) cat '$STATE/mounts'; exit 0 ;;
        esac
        echo '[{}]'; exit 0 ;;
    'start dx-hp') : > '$STATE/running'; exit 0 ;;
esac
if [ \"\$1 \$2 \$3\" = 'create --name dx-hp' ]; then
    for a in \"\$@\"; do
        case \"\$a\" in
            *\$'\\n'*) a='<MULTILINE-ARG>' ;;
            HOST_TZ=*) a='HOST_TZ=<tz>' ;;
        esac
        printf '%s\\n' \"\$a\" >> '$ARGV'
    done
    : > '$STATE/container'
    for a in \"\$@\"; do
        case \"\$a\" in type=bind,source=*,target=/persist*) src=\"\${a#type=bind,source=}\"; src=\"\${src%%,target=*}\"; printf 'bind|%s|/persist|rw\\n' \"\$src\" > '$STATE/mounts' ;; esac
    done
    exit 0
fi
case \"\$1\" in create | rm | stop | kill) exit 0 ;; esac
echo \"UNMATCHED: \$*\" >&2; exit 99"
    : > "$STATE/image"
    printf 'dx_key\n' > "$RBIN/home/keys/dx_key"
    printf 'dx_key.pub\n' > "$RBIN/home/keys/dx_key.pub"
}

# vol NAME ROLE: the volume exists in the docker fake, labelled for ROLE.
vol() { printf 'true|1|%s|%s|x86_64-linux\n' "$PROFILE" "$2" > "$VOLS/$1"; }

# make_dir [SOURCE_VOLUME]: the ready directory, user work and R28 state.
make_dir() {
    mkdir -p "$ROOT/dxe/dx-hp/persist/home/dx/.cache"
    dx_persist_marker_format dx-hp ready "${1:-}" 2025-01-02T03:04:05Z > "$ROOT/dxe/dx-hp/persist/.dxe-persist-dir"
    printf 'user work\n' > "$ROOT/dxe/dx-hp/persist/work.txt"
    ln -s /nix/store/0000000000000000000000000000000a-fake-tool-1.0/bin/tool \
        "$ROOT/dxe/dx-hp/persist/home/dx/.cache/tool-link"
    ln -s /nix/store/0000000000000000000000000000000b-gone "$ROOT/dxe/dx-hp/persist/profile-link"
}
RECORD_DIR=""
make_record() {
    RECORD_DIR="$RBIN/xdg/dxe/persist-dirs"
    mkdir -p "$RECORD_DIR"
    printf 'record: %s\n' "$PROFILE" > "$RECORD_DIR/$PROFILE"
}
record_path() { printf '%s/xdg/dxe/persist-dirs/%s' "$RBIN" "$PROFILE"; }

# snap DIR: every path with its type, symlink target and file checksum.
snap() {
    (
        cd -P -- "$1" || exit 1
        find . | LC_ALL=C sort | while IFS= read -r p; do
            if [ -L "$p" ]; then printf 'L %s -> %s\n' "$p" "$(readlink "$p")"
            elif [ -f "$p" ]; then printf 'F %s %s\n' "$p" "$(cksum <"$p")"
            elif [ -d "$p" ]; then printf 'D %s\n' "$p"
            else printf 'O %s\n' "$p"; fi
        done
    )
}
rec_sig() { cksum < "$(record_path)" 2>/dev/null || echo none; }
persist_vols_sig() {
    local f
    for f in "$VOLS"/*persist* "$VOLS"/*old*; do
        [ -f "$f" ] && printf '%s %s\n' "${f##*/}" "$(cksum < "$f")"
    done
    return 0
}

# run_cmd NAME [ARGS...]: one real entry point from the scratch bin/, in a
# clean environment. Sets OUT (stdout), ERR (stderr) and RC.
run_cmd() {
    local cmd="$1"
    shift
    env -i HOME="$RBIN/home" XDG_STATE_HOME="$RBIN/xdg" TMPDIR="$fixture" \
        PATH="$TOOLS:/usr/bin:/bin" \
        DX_RUNTIME=docker-ssh DX_REMOTE_HOST="$NAS" DX_GUEST_SYSTEM=x86_64-linux \
        DX_NIX_STORAGE_MODE=direct-volume DX_CONTAINER_NAME=dx-hp DX_IMAGE=dx-hp-nixos \
        DX_NIX_VOLUME=dx-hp-nix DX_PERSIST_VOLUME=dx-hp-persist DX_BOOTSTRAP_VOLUME=dx-hp-bootstrap \
        DX_BOOTSTRAP_PATH=/guest-bootstrap DX_GUEST_ACTIVATION_TIMEOUT=1800 \
        DX_GUEST_ACTIVATION_ATTEMPTS=2 DX_GUEST_ACTIVATION_RETRY_DELAY=5 DX_NIX_DISK_SIZE=64G \
        DX_CONTAINER_MEMORY=12G DX_CONTAINER_CPUS=4 DX_SSH_PORT=2222 DX_CONTAINER_RESTART_POLICY=no \
        DX_GIT_MOUNT_SOURCE='' DX_SSH_KEY="$RBIN/home/keys/dx_key" \
        DX_SSH_KEY_PUB="$RBIN/home/keys/dx_key.pub" \
        DX_PERSIST_STORAGE=host-path "DX_PERSIST_HOST_ROOT=$ROOT" \
        DXE_FAKE_SSH_REMOTE_PATH="$RBIN" \
        "$SBIN/$cmd" "$@" < /dev/null > "$RBIN/out" 2> "$RBIN/err"
    RC=$?
    OUT="$(cat "$RBIN/out")"
    ERR="$(cat "$RBIN/err")"
}

# bring_up: bin/dx's child loop (minus keys and wait-ssh, see the header);
# stops at the first failing child like dx_connect_or_bring_up. Sets BU_RC,
# BU_OUT, BU_ERR and BU_STOPPED_AT.
bring_up() {
    local child
    BU_RC=0; BU_OUT=""; BU_ERR=""; BU_STOPPED_AT=""
    for child in dx-create-image dx-create-volumes dx-create-container dx-start-container; do
        run_cmd "$child"
        BU_OUT="$BU_OUT$OUT"$'\n'; BU_ERR="$BU_ERR$ERR"$'\n'
        if [ "$RC" -ne 0 ]; then BU_RC=$RC; BU_STOPPED_AT=$child; return 0; fi
    done
    return 0
}

has_line() { grep -Fqx -- "$2" <<<"$1"; }
count_errors() { grep -c '^Error:' <<<"$1" || true; }
mounts_in_argv() { grep -Fxc -- --mount "$ARGV" || true; }
persist_rm_or_create() { cat "$RMLOG" "$CRLOG" | grep -E 'persist|old' || true; }
restage_keys() {
    printf 'dx_key\n' > "$RBIN/home/keys/dx_key"; printf 'dx_key.pub\n' > "$RBIN/home/keys/dx_key.pub"
    : > "$DLOG"; : > "$RMLOG"; : > "$CRLOG"; : > "$DESTLOG"
}

# --- the reuse scenarios -----------------------------------------------------
reuse_case() { # LABEL SOURCE_VOLUME PERSIST_VOLUMES...
    local label="$1" source_volume="$2" v sig rec vsig dir_want
    shift 2
    new_world; make_dir "$source_volume"; make_record
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap
    for v in "$@"; do vol "$v" persist; done
    sig="$(snap "$ROOT")"; rec="$(rec_sig)"; vsig="$(persist_vols_sig)"
    dir_want="$ROOT/dxe/dx-hp/persist"

    run_cmd dx-factory-reset --force
    if [ "$RC" -eq 0 ] && has_line "$OUT" "Factory reset complete."; then
        test_pass "$label: the factory reset succeeds"
    else test_fail "$label: the factory reset succeeds (rc=$RC out: $OUT err: $ERR)"; fi
    if [ "$(cat "$RMLOG")" = "$(printf 'dx-hp-nix\ndx-hp-bootstrap')" ] && [ -z "$(persist_rm_or_create)" ]; then
        test_pass "$label: the reset removes the nix and bootstrap volumes and no persist volume"
    else test_fail "$label: the reset removes nix and bootstrap only (rm: $(cat "$RMLOG"))"; fi
    if [ "$(snap "$ROOT")" = "$sig" ] && [ "$(rec_sig)" = "$rec" ] && [ ! -s "$DESTLOG" ]; then
        test_pass "$label: after the reset the directory, marker, user files and record are byte-identical"
    else test_fail "$label: after the reset the share and record are unchanged (destructive: $(cat "$DESTLOG"))"; fi
    if [ "$(readlink "$dir_want/home/dx/.cache/tool-link")" = /nix/store/0000000000000000000000000000000a-fake-tool-1.0/bin/tool ] \
        && [ "$(readlink "$dir_want/profile-link")" = /nix/store/0000000000000000000000000000000b-gone ]; then
        test_pass "$label: R28 observable part: kept links into the deleted /nix store are neither removed nor rewritten"
    else test_fail "$label: kept links into /nix are intact after the reset"; fi
    if [ ! -e "$RBIN/home/keys/dx_key" ]; then test_pass "$label: the reset removed the key pair (the bring-up regenerates it)"
    else test_fail "$label: the reset removed the key pair"; fi
    restage_keys

    bring_up
    if [ "$BU_RC" -eq 0 ] && [ -z "$BU_STOPPED_AT" ] && [ "$(count_errors "$BU_ERR$BU_OUT")" = 0 ]; then
        test_pass "$label: the bring-up chain succeeds with no Error line"
    else test_fail "$label: the bring-up chain succeeds (stopped at $BU_STOPPED_AT rc=$BU_RC err: $BU_ERR out: $BU_OUT)"; fi
    if has_line "$BU_OUT" "Using /persist directory $dir_want (marker ready)."; then
        test_pass "$label: the existing ready directory is the one reused"
    else test_fail "$label: the existing ready directory is the one reused (out: $BU_OUT)"; fi
    if [ "$(snap "$ROOT")" = "$sig" ] && [ ! -s "$DESTLOG" ]; then
        test_pass "$label: nothing is created on the share and no mkdir/establish command runs"
    else test_fail "$label: nothing is created on the share (before: $sig | after: $(snap "$ROOT") | destructive: $(cat "$DESTLOG"))"; fi
    if [ "$(rec_sig)" = "$rec" ] && [ "$(ls "$RECORD_DIR" | wc -l | tr -d ' ')" = 1 ]; then
        test_pass "$label: the record still exists, byte-identical"
    else test_fail "$label: the record is byte-identical"; fi
    if [ "$(sort "$CRLOG" | tr '\n' ' ')" = "dx-hp-bootstrap dx-hp-nix " ] && [ -z "$(persist_rm_or_create)" ]; then
        test_pass "$label: only the nix and bootstrap volumes are recreated"
    else test_fail "$label: only nix and bootstrap are created (created: $(cat "$CRLOG"))"; fi
    if [ "$(persist_vols_sig)" = "$vsig" ]; then
        test_pass "$label: the persist volume state is untouched"
    else test_fail "$label: the persist volume state is untouched"; fi
    if [ "$(mounts_in_argv)" = 1 ] && grep -Fxq "type=bind,source=$dir_want,target=/persist" "$ARGV" \
        && ! grep -Eq ':/persist(:|$)' "$ARGV"; then
        test_pass "$label: the container is created with exactly one --mount of the existing directory"
    else test_fail "$label: the create mounts the existing directory (argv: $(tr '\n' ' ' < "$ARGV"))"; fi
    if [ "$(grep -Fxc 'start dx-hp' "$DLOG")" = 1 ]; then
        test_pass "$label: the container is started, once"
    else test_fail "$label: the container is started once (docker: $(cat "$DLOG"))"; fi
}

reuse_case "reuse, host-path guest (no persist volume)" ""
reuse_case "reuse, migrated guest (volumes kept)" dx-hp-old dx-hp-persist dx-hp-old

# --- refusal scenarios -------------------------------------------------------
refuse_case() { # LABEL WITH_RECORD(yes|no) KEYWORDS... -- PERSIST_VOLUMES...
    local label="$1" with_record="$2" kw v n_err err_line sig
    local keywords=() volumes=()
    shift 2
    while [ "$#" -gt 0 ] && [ "$1" != -- ]; do keywords+=("$1"); shift; done
    shift
    volumes=("$@")
    new_world
    if [ "$with_record" = yes ]; then make_record; fi
    vol dx-hp-nix nix; vol dx-hp-bootstrap bootstrap
    for v in "${volumes[@]+"${volumes[@]}"}"; do vol "$v" persist; done
    sig="$(snap "$ROOT")"

    run_cmd dx-factory-reset --force
    if [ "$RC" -eq 0 ] && grep -Fq "Kept /persist host directory: $ROOT/dxe/dx-hp/persist" <<<"$OUT"; then
        test_pass "$label: the reset still succeeds and reports the kept directory"
    else test_fail "$label: the reset still succeeds (rc=$RC out: $OUT)"; fi
    restage_keys

    bring_up
    if [ "$BU_RC" -ne 0 ] && [ "$BU_STOPPED_AT" = dx-create-volumes ]; then
        test_pass "$label: the bring-up refuses at dx-create-volumes"
    else test_fail "$label: the bring-up refuses at dx-create-volumes (stopped at [$BU_STOPPED_AT] rc=$BU_RC)"; fi
    n_err="$(count_errors "$BU_ERR")"
    if [ "$n_err" = 1 ] && [ "$(count_errors "$BU_OUT")" = 0 ]; then
        test_pass "$label: exactly one Error line, on stderr"
    else test_fail "$label: exactly one Error line, on stderr (stderr: $BU_ERR | stdout: $BU_OUT)"; fi
    err_line="$(grep '^Error:' <<<"$BU_ERR" || true)"
    for kw in "${keywords[@]}"; do
        kw="${kw//@DIR@/$ROOT/dxe/dx-hp/persist}"
        kw="${kw//@REC@/$(record_path)}"
        if grep -Fq -- "$kw" <<<"$err_line"; then test_pass "$label: the Error line carries [$kw]"
        else test_fail "$label: the Error line carries [$kw] (stderr: $BU_ERR)"; fi
    done
    if [ ! -s "$CRLOG" ] && [ ! -s "$RMLOG" ] && [ ! -s "$ARGV" ] && ! grep -Eq '^(create|start|volume create|volume rm) ' "$DLOG" \
        && [ ! -s "$DESTLOG" ]; then
        test_pass "$label: nothing is created or started (no volume, no container, no start, no mkdir)"
    else test_fail "$label: nothing is created or started (docker: $(cat "$DLOG") destructive: $(cat "$DESTLOG"))"; fi
    if [ "$(snap "$ROOT")" = "$sig" ] && [ ! -e "$ROOT/dxe" ]; then
        test_pass "$label: nothing is created on the share"
    else test_fail "$label: nothing is created on the share (after: $(snap "$ROOT"))"; fi
    if [ "$with_record" = yes ] && [ -f "$(record_path)" ]; then test_pass "$label: the record is still there"
    elif [ "$with_record" = no ] && [ ! -e "$RBIN/xdg/dxe/persist-dirs" ]; then test_pass "$label: no record is invented"
    else test_fail "$label: the record state is unchanged"; fi
}

refuse_case "missing directory, record present" yes @DIR@ @REC@ --
refuse_case "missing directory, record present, persist volume kept" yes @DIR@ @REC@ dx-persist-migrate -- dx-hp-persist
refuse_case "missing directory, no record, persist volume kept" no @DIR@ dx-persist-migrate -- dx-hp-persist

print_summary
exit_with_code
