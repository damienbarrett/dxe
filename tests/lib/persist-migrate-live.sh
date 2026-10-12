#!/bin/bash
# shellcheck disable=SC2034 # every constant here is read by the sourcing suites
# tier: unit
# bash32: yes
# Import-only (functions and constants; no output, no shell-option or trap
# changes, no I/O at import time). Bash 3.2 compatible. Needs
# tests/lib/persist-live.sh sourced first (its guard, confinement and names).
#
# The guard and helpers of the /persist MIGRATION live suite
# (tests/test_persist_migrate_live.sh, plans/do WP7.2; spec section 9 W4,
# R31-R37), kept out of the suite so tests/test_persist_migrate_live_guard.sh
# can unit-test every refusal, every pinned argv and every script without a
# NAS.
#
# Contract (pinned by tests/test_persist_migrate_live_guard.sh):
#
# persist_migrate_live_guard
#   persist_live_guard (every WP7.1 rule, on the profile as installed: it is a
#   host-path canary profile; the suite itself switches DX_PERSIST_STORAGE and
#   DX_PERSIST_VOLUME per phase), plus one `Refusing: ...` line on stderr for
#   each of these it breaks, status 1; silent status 0 when all hold. No
#   command, remote or file-system call.
#     - DX_PERSIST_HOST_ROOT holds no "," (the suite's own --mount options);
#     - the rollback volume (persist_migrate_live_rollback_volume) is a canary
#       volume name (contains "canary", only [a-z0-9-], starts dx-) and is none
#       of DX_NIX_VOLUME, DX_PERSIST_VOLUME, DX_BOOTSTRAP_VOLUME;
#     - DXE_PERSIST_LIVE_BULK_MIB is empty or a whole number 64..16384;
#     - DXE_PERSIST_LIVE_INVENTORY_REAL is empty or exactly dx-qnap, and is
#       never combined with DXE_PERSIST_LIVE_CLEANUP_ONLY=1.
#
# persist_migrate_live_rollback_volume
#   DXE_PERSIST_LIVE_ROLLBACK_VOLUME, or <DX_PERSIST_VOLUME>-rollback.
# persist_migrate_live_bulk_mib
#   DXE_PERSIST_LIVE_BULK_MIB, or 2048 (the guard validates it).
#
# persist_migrate_live_dir_read SCRIPT [ARG...]
#   Read-only twin of persist_live_root_sh for bash scripts: refuses (status 2,
#   one `Refusing:` line, no call) unless persist_live_share_path_ok accepts
#   the canary directory and the root holds no ","; otherwise exactly one call:
#     dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0
#       --pull never --label dxe.role=persist-live
#       --mount type=bind,source=<canary dir>,target=/canary,readonly
#       --entrypoint bash <DX_IMAGE> -c SCRIPT bash /canary [ARG...]
#
# persist_migrate_live_volume_read VOLUME SCRIPT [ARG...]
#   Refuses (status 2, one `Refusing:` line, no call) unless VOLUME contains
#   "canary", is a plain volume name, equals DX_PERSIST_VOLUME (so its DQ6 role
#   is persist) and is neither DX_NIX_VOLUME nor DX_BOOTSTRAP_VOLUME, and
#   DX_IMAGE contains "canary". Then the DQ6 check, and only if it passes the
#   read, each exactly one call:
#     dxe_runtime_call dx_runtime_volume_owned VOLUME "read (live suite)"
#     dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0
#       --pull never --label dxe.role=persist-live -v VOLUME:/v:ro
#       --entrypoint bash <DX_IMAGE> -c SCRIPT bash /v [ARG...]
#   A failed ownership check (an absent volume included: docker run -v would
#   create it) returns its status with no run.
#
# persist_migrate_live_interrupt DOCKER_BIN CANON_LEAF DEADLINE
#   Refuses (status 2, one `Refusing:` line, no call) unless DOCKER_BIN is an
#   absolute path without spaces, DX_IMAGE and DX_PERSIST_VOLUME contain
#   "canary", CANON_LEAF is a normalised absolute path without "," that ends in
#   /dxe/<DX_CONTAINER_NAME>/persist with a canary name, and DEADLINE is a
#   whole number 10..3600. Otherwise exactly one call, the NAS shell running
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT:
#     dxe_runtime_call dx_runtime_docker_ssh_exec sh -c SCRIPT dxe-live-interrupt
#       DOCKER_BIN DX_IMAGE DX_PERSIST_VOLUME CANON_LEAF dxe-live-bulk
#       dxe-live-blob.bin DEADLINE
#
# persist_migrate_live_real_inventory PROFILE ROOT COMMAND
#   The opt-in read-only inventory of the production guest. Resolves PROFILE's
#   file like bin/dx-profile (DX_PROFILES_DIR, else ~/.config/dxe/profiles,
#   then tests/profiles), parses it with the repository's own parser, and
#   refuses (status 2, one `Refusing:` line, nothing run) unless it resolves
#   and parses, names DX_CONTAINER_NAME=dx-qnap (and DXE_PERSIST_LIVE_INVENTORY_REAL
#   says dx-qnap), DX_RUNTIME=docker-ssh and a DX_PERSIST_VOLUME, COMMAND's
#   file name is dx-persist-inventory and XDG_STATE_HOME is set. Then it execs
#   COMMAND under `env -i` with HOME, PATH, XDG_STATE_HOME, TMPDIR (and
#   SSH_AUTH_SOCK when set), every field the profile sets EXCEPT
#   DX_PROFILE_ROOT (the production profile pins the main checkout, which has
#   no dx-persist-inventory), and DX_PERSIST_HOST_ROOT=ROOT when the profile
#   sets none. Nothing of the canary's configuration reaches it.
#
# Scripts. Container and NAS-shell scripts are ONE line with no single quote
# (as tests/lib/persist-live.sh's); guest scripts run in the guest's bash 5
# through dx-ssh and may span lines (still no single quote).
#   PERSIST_MIGRATE_LIVE_SCRIPT_LIST (bash; $1 base, $2 a relative subtree
#     without ".."): a manifest-like listing, one TAB-separated record per
#     entry in bytewise path order, then `end<TAB><count>`:
#       TYPE MODE OWNER SIZE MTIME NLINK CKSUM GROUP TARGET PATH
#     TYPE f d l p s b c; MODE and OWNER as stat prints them (numeric);
#     SIZE for f and l, else -; MTIME whole seconds; NLINK for non-directories,
#     else -; CKSUM the POSIX cksum CRC for f, else -; GROUP for a
#     non-directory sharing its inode with an earlier entry of the listing, the
#     first such path, for any other multiply linked non-directory its own
#     path, else -; TARGET a symlink's target, else -; PATH "." or "./...".
#     GROUP, TARGET and PATH escape "\" as "\\", TAB as "\t", newline as
#     "\n". Uses only bash, find, sort, stat, cksum and readlink (the bare
#     image has them all; GNU or BSD stat). Any failure: non-zero status.
#   PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE (sh, through persist_live_root_sh
#     rw; $2 bulk dir, $3 blob): moves every regular file named
#     persist/$2/.$3.?????? (rsync's temp file of the blob) into
#     rsync-temp.dxe-live-aside/ (made 0700 when missing) with mv, one
#     `moved=<name>` line each; refuses symlinked or missing levels, an
#     existing target; status 3 when there is none. Deletes nothing.
#   PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE (sh, through persist_live_root_sh
#     rw; $2 guest, $3 a UTC stamp): the runbook's "move the retired directory
#     aside": mv persist persist.retired-$3, only when persist is a real
#     directory whose regular marker has exactly one guest=$2 line, no other
#     guest= line, exactly one state=retired line and no other state= line,
#     and the target is free. Deletes nothing.
#   PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT (sh in the NAS shell; see
#     persist_migrate_live_interrupt): waits (sleep 1 between docker ps calls,
#     DEADLINE seconds in all) for exactly one RUNNING container that mounts
#     the volume $3, runs the guest-volume rsync with
#     "-aH --numeric-ids ... /src/ /dst/" and binds $4 at /dst. Those three
#     are what single out the copy; `--filter ancestor=$2` only narrows the
#     list (a tag of the shared nixos/nix base, so the production guest's
#     containers can match it too). Then it waits for rsync's temp file of
#     the blob ($4/$5/.$6.??????), polling every 0.05 s and checking the
#     container every 20 polls when the NAS's sleep takes fractions, else
#     every second (never a busy loop against the Docker daemon), and sends
#     that one container `docker kill` (SIGKILL) at once, then waits until
#     --rm has removed it. The trigger is rsync's temp file: if the copy ever
#     uses rsync --inplace (no temp file; a WP6.4 follow-up may), this
#     trigger never fires and needs another progress signal. Prints copy=<id12>, interrupted=<id12>
#     temp=<name>, gone=<id12>. Status: 0 done; 1 bad arguments; 2 no copy
#     container before the deadline; 3 the copy container ended before the
#     temp file appeared; 4 a docker call failed; 5 the killed container did
#     not go away; 6 more than one container matched (none is touched); 7
#     this account cannot list $4/$5 (nothing is killed).
# persist_migrate_live_listing_ok FILE
#   0 only when FILE (a LIST output) ends with `end<TAB>N` and holds exactly N
#   records before it, N > 0: a listing cut short is never compared.
# persist_migrate_live_records FILE
#   The records of FILE (every line but the `end` line).
# persist_migrate_live_records_without_apple FILE
#   The records whose PATH has no component starting with "._" (what rsync's
#   --exclude='._*' and the manifest drop, at any depth).
#
#   PERSIST_MIGRATE_LIVE_GUEST_SEED (bash; $1 /persist, $2 token, $3 MiB):
#     the seeded tree (below) and the bulk blob; prints
#     `seeded=ok socket=yes|no bulk_bytes=<n>`; refuses an existing tree.
#   PERSIST_MIGRATE_LIVE_GUEST_CHANGES (bash; $1 /persist, $2 token): write,
#     overwrite, delete (one file and one hard link), rename (a file and a
#     directory), and a new ._* file; prints `changed=ok`.
#   PERSIST_MIGRATE_LIVE_GUEST_CHECK (bash; $1 /persist, $2 seeded | migrated
#     | changed-dir | changed-volume, $3 token, $4 changes token, $5 socket
#     yes|no, $6 bulk bytes): one `ok <name>` or `bad <name>` line per check,
#     then `checks=<n> bad=<m>`; status 0 only when m is 0.

PERSIST_MIGRATE_LIVE_REAL_GUEST=dx-qnap
PERSIST_MIGRATE_LIVE_REAL_PROFILE=qnap
PERSIST_MIGRATE_LIVE_SEED=dxe-live-seed
PERSIST_MIGRATE_LIVE_BULK=dxe-live-bulk
PERSIST_MIGRATE_LIVE_BLOB=dxe-live-blob.bin
PERSIST_MIGRATE_LIVE_TEMP_ASIDE=rsync-temp.dxe-live-aside
PERSIST_MIGRATE_LIVE_RETIRED_PREFIX=persist.retired-
PERSIST_MIGRATE_LIVE_BULK_MIB_DEFAULT=2048
PERSIST_MIGRATE_LIVE_RSYNC_BIN=/nix/var/nix/profiles/per-user/root/profile/bin/rsync
# The two ._* files the seed drops in, as the inventory and the reports name
# them (paths below the volume or directory root, in sorted order).
PERSIST_MIGRATE_LIVE_SEED_APPLE="dxe-live-seed/._dxe-live-meta dxe-live-seed/nested/deeper/._deep-meta"
PERSIST_MIGRATE_LIVE_CHANGES_APPLE=dxe-live-seed/._rollback-meta

PERSIST_MIGRATE_LIVE_SCRIPT_LIST='export LC_ALL=C; set -o pipefail; '\
'case "$2" in "" | /* | .. | ../* | */.. | */../*) echo "dxe-live-list: bad subtree $2" >&2; exit 2 ;; esac; '\
'cd -P -- "$1" || exit 1; cd -P -- "$2" || exit 1; '\
'nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; bs=\\; '\
'esc() { local v=${1//"$bs"/"$bs$bs"}; v=${v//"$tb"/"${bs}t"}; E=${v//"$nl"/"${bs}n"}; }; '\
'st() { stat -c "%a %u:%g %s %Y %h %d:%i" -- "$1" 2>/dev/null || stat -f "%Lp %u:%g %z %m %l %d:%i" -- "$1"; }; '\
'find . -print0 | sort -z | { seen=$nl; n=0; while IFS= read -r -d "" p; do '\
'if [ -L "$p" ]; then t=l; elif [ -d "$p" ]; then t=d; elif [ -f "$p" ]; then t=f; elif [ -p "$p" ]; then t=p; elif [ -S "$p" ]; then t=s; elif [ -b "$p" ]; then t=b; elif [ -c "$p" ]; then t=c; else echo "dxe-live-list: unknown type: $p" >&2; exit 1; fi; '\
's=$(st "$p") || exit 1; set -- $s; [ "$#" -eq 6 ] || exit 1; '\
'sz=-; lk=-; ck=-; gr=-; tg=-; '\
'case "$t" in f | l) sz=$3 ;; esac; '\
'[ "$t" = d ] || lk=$5; '\
'if [ "$t" = f ]; then ck=$(cksum < "$p") || exit 1; ck=${ck%% *}; fi; '\
'if [ "$t" = l ]; then tg=$(readlink -- "$p") || exit 1; esc "$tg"; tg=$E; fi; '\
'esc "$p"; '\
'if [ "$t" != d ] && [ "$5" -gt 1 ]; then case "$seen" in *"$nl$6$tb"*) r=${seen#*"$nl$6$tb"}; gr=${r%%"$nl"*} ;; *) seen="$seen$6$tb$E$nl"; gr=$E ;; esac; fi; '\
'printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$t" "$1" "$2" "$sz" "$4" "$lk" "$ck" "$gr" "$tg" "$E"; n=$((n + 1)); '\
'done; printf "end\t%s\n" "$n"; } || exit 1'

PERSIST_MIGRATE_LIVE_SCRIPT_TEMP_ASIDE="$PERSIST_LIVE_SCRIPT_PRELUDE"\
'case "$2" in "" | . | .. | *[!A-Za-z0-9._-]*) echo "dxe-live: bad directory name $2" >&2; exit 2 ;; esac; '\
'case "$3" in "" | *[!A-Za-z0-9._-]*) echo "dxe-live: bad file name $3" >&2; exit 2 ;; esac; '\
'if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; '\
'b="persist/$2"; if [ -L "$b" ] || [ ! -d "$b" ]; then echo "dxe-live: $b is not a real directory" >&2; exit 1; fi; '\
'a=rsync-temp.dxe-live-aside; if [ -L "$a" ] || { [ -e "$a" ] && [ ! -d "$a" ]; }; then echo "dxe-live: $a is not a directory" >&2; exit 1; fi; '\
'n=0; for f in "$b/.$3".??????; do if [ -f "$f" ] && [ ! -L "$f" ]; then '\
'if [ ! -d "$a" ]; then mkdir -m 0700 -- "$a" || exit 1; fi; '\
't="$a/${f##*/}"; if [ -e "$t" ] || [ -L "$t" ]; then echo "dxe-live: $t already exists" >&2; exit 1; fi; '\
'mv -- "$f" "$t" || exit 1; echo "moved=${f##*/}"; n=$((n + 1)); fi; done; '\
'if [ "$n" -eq 0 ]; then echo "dxe-live: no rsync temp file of $3 in $b" >&2; exit 3; fi'

PERSIST_MIGRATE_LIVE_SCRIPT_RETIRED_ASIDE="$PERSIST_LIVE_SCRIPT_PRELUDE"\
'case "$3" in "" | *[!0-9TZ]*) echo "dxe-live: bad stamp $3" >&2; exit 2 ;; esac; '\
'if [ -L persist ] || [ ! -d persist ]; then echo "dxe-live: persist is not a real directory" >&2; exit 1; fi; '\
'm=persist/.dxe-persist-dir; if [ -L "$m" ] || [ ! -f "$m" ]; then echo "dxe-live: no regular marker in persist" >&2; exit 1; fi; '\
'g=0; s=0; while IFS= read -r l || [ -n "$l" ]; do case "$l" in "guest=$2") g=$((g + 1)) ;; guest=*) g=9 ;; state=retired) s=$((s + 1)) ;; state=*) s=9 ;; esac; done < "$m"; '\
'if [ "$g" -ne 1 ] || [ "$s" -ne 1 ]; then echo "dxe-live: persist is not marked retired for $2; it stays where it is" >&2; exit 1; fi; '\
't="persist.retired-$3"; if [ -e "$t" ] || [ -L "$t" ]; then echo "dxe-live: $t already exists" >&2; exit 1; fi; '\
'mv -- persist "$t"'

# The trigger below is rsync's temp file of the bulk file. A copy run with
# rsync --inplace (a possible WP6.4 follow-up for the stale-temp-file gap)
# writes no temp file, so this trigger would never fire: give the watcher
# another progress signal before changing the copy's options.
PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT='d=$1; img=$2; vol=$3; dst=$4; tmp="$4/$5/.$6"; '\
'rs=/nix/var/nix/profiles/per-user/root/profile/bin/rsync; '\
'case "$1" in /*) : ;; *) echo "dxe-live-interrupt: the docker CLI path must be absolute" >&2; exit 1 ;; esac; '\
'case "$7" in "" | *[!0-9]*) echo "dxe-live-interrupt: bad deadline $7" >&2; exit 1 ;; esac; '\
'if [ -z "$2" ] || [ -z "$3" ] || [ -z "$5" ] || [ -z "$6" ]; then echo "dxe-live-interrupt: missing arguments" >&2; exit 1; fi; '\
'case "$4" in /*/persist) : ;; *) echo "dxe-live-interrupt: bad destination $4" >&2; exit 1 ;; esac; '\
'now() { date +%s; }; end=$(( $(now) + $7 )); fs=0; ev=1; if sleep 0.05 2>/dev/null; then fs=1; ev=20; fi; '\
'id=""; while [ -z "$id" ]; do '\
'ids=$("$d" ps -q --no-trunc --filter "ancestor=$img" --filter "volume=$vol" --filter status=running) || { echo "dxe-live-interrupt: docker ps failed" >&2; exit 4; }; '\
'n=0; c=""; for i in $ids; do '\
'x=$("$d" inspect --format "{{.Path}}|{{range .Args}}{{.}} {{end}}|{{range .Mounts}}{{.Destination}}={{.Source}};{{end}}" "$i" 2>/dev/null) || continue; '\
'case "$x" in "$rs|-aH --numeric-ids "*" /src/ /dst/ |"*) : ;; *) continue ;; esac; '\
'case "$x" in *"|/dst=$dst;"* | *";/dst=$dst;"*) : ;; *) continue ;; esac; '\
'n=$((n + 1)); c=$i; done; '\
'if [ "$n" -gt 1 ]; then echo "dxe-live-interrupt: $n copy containers match; touching none" >&2; exit 6; fi; '\
'if [ "$n" -eq 1 ]; then id=$c; echo "copy=$(printf "%.12s" "$id")"; break; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: no copy container appeared within $7 s" >&2; exit 2; fi; '\
'sleep 1; done; '\
'hit=""; k=0; while [ -z "$hit" ]; do '\
'for f in "$tmp".??????; do if [ -f "$f" ] && [ ! -L "$f" ]; then hit=$f; fi; done; '\
'if [ -n "$hit" ]; then break; fi; k=$((k + 1)); '\
'if [ $((k % ev)) -eq 0 ]; then if [ -d "$4/$5" ] && { [ ! -r "$4/$5" ] || [ ! -x "$4/$5" ]; }; then echo "dxe-live-interrupt: this account cannot list $4/$5, so it cannot see the copy progress; nothing was killed" >&2; exit 7; fi; '\
'r=$("$d" inspect --format "{{.State.Running}}" "$id" 2>/dev/null) || r=gone; '\
'if [ "$r" != true ]; then echo "dxe-live-interrupt: the copy container ended before the temp file of $6 appeared" >&2; exit 3; fi; '\
'if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: no temp file of $6 within $7 s" >&2; exit 2; fi; fi; '\
'if [ "$fs" = 1 ]; then sleep 0.05; else sleep 1; fi; done; '\
'"$d" kill "$id" >/dev/null || { echo "dxe-live-interrupt: docker kill failed" >&2; exit 4; }; '\
'echo "interrupted=$(printf "%.12s" "$id") temp=${hit##*/}"; '\
'while "$d" inspect "$id" >/dev/null 2>&1; do if [ "$(now)" -ge "$end" ]; then echo "dxe-live-interrupt: the killed container did not go away" >&2; exit 5; fi; sleep 1; done; '\
'echo "gone=$(printf "%.12s" "$id")"'

PERSIST_MIGRATE_LIVE_GUEST_SEED='set -eu
r=$1; s="$r/dxe-live-seed"; b="$r/dxe-live-bulk"
case "$3" in "" | *[!0-9]*) echo "dxe-live-seed: bad MiB $3" >&2; exit 2 ;; esac
if [ -e "$s" ] || [ -L "$s" ] || [ -e "$b" ] || [ -L "$b" ]; then echo "dxe-live-seed: $s or $b already exists" >&2; exit 1; fi
umask 022
nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; q=$(printf "\047"); u=$(printf "\303\274n\303\257c\303\270d\303\251")
mkdir -p "$s/nested/deeper" "$s/odd names" "$s/private" "$s/dir-to-rename/inner" "$b"
printf "%s\n" "$2" > "$s/app-state.txt"
printf "alpha\n" > "$s/hardlink-a"
ln "$s/hardlink-a" "$s/hardlink-b"
ln "$s/hardlink-a" "$s/nested/hardlink-c"
printf "mac metadata\n" > "$s/._dxe-live-meta"
printf "deep mac metadata\n" > "$s/nested/deeper/._deep-meta"
mkfifo "$s/fifo"
ln -s hardlink-a "$s/link-to-a"
ln -s does-not-exist "$s/dangling"
ln -s nested "$s/link-to-dir"
ln -s "$s/app-state.txt" "$s/absolute-link"
printf "secret\n" > "$s/private/key"
chmod 0600 "$s/private/key"
chmod 0700 "$s/private"
printf "#!/bin/sh\necho run\n" > "$s/run.sh"
chmod 0755 "$s/run.sh"
: > "$s/empty-file"
printf "to delete\n" > "$s/nested/to-delete.txt"
printf "to rename\n" > "$s/to-rename.txt"
printf "before\n" > "$s/nested/modified.txt"
printf "inner\n" > "$s/dir-to-rename/inner/file.txt"
for n in "with space.txt" "-leading-dash" "tab${tb}name" "quote${q}single" "quote\"double" "back\\slash" "star*glob?" "dollar\$HOME" "$u" "new${nl}line"; do
  printf "odd\n" > "$s/odd names/$n"
done
sock=no
if command -v tmux >/dev/null 2>&1; then
  tmux -S "$s/dxe-live.sock" -f /dev/null new-session -d -s dxe-live-seed true >/dev/null 2>&1 || :
  if [ -S "$s/dxe-live.sock" ]; then sock=yes; fi
fi
bytes=$(( $3 * 1048576 ))
head -c "$bytes" /dev/urandom > "$b/dxe-live-blob.bin"
echo "seeded=ok socket=$sock bulk_bytes=$bytes"'

PERSIST_MIGRATE_LIVE_GUEST_CHANGES='set -eu
s="$1/dxe-live-seed"
[ -d "$s" ] || { echo "dxe-live-changes: no $s" >&2; exit 1; }
printf "%s\n" "$2" > "$s/written-after-switch.txt"
printf "after\n" > "$s/nested/modified.txt"
rm -f -- "$s/nested/to-delete.txt" "$s/hardlink-b"
mv -- "$s/to-rename.txt" "$s/renamed.txt"
mv -- "$s/dir-to-rename" "$s/dir-renamed"
printf "mac metadata after the switch\n" > "$s/._rollback-meta"
echo "changed=ok"'

PERSIST_MIGRATE_LIVE_GUEST_CHECK='s="$1/dxe-live-seed"; blob="$1/dxe-live-bulk/dxe-live-blob.bin"; n=0; bad=0
yes_() { n=$((n + 1)); echo "ok $1"; }
no_() { n=$((n + 1)); bad=$((bad + 1)); echo "bad $1"; }
chk() { local name=$1; shift; if "$@"; then yes_ "$name"; else no_ "$name"; fi; }
nlink() { stat -c %h -- "$1" 2>/dev/null || stat -f %l -- "$1"; }
mode() { stat -c %a -- "$1" 2>/dev/null || stat -f %Lp -- "$1"; }
size() { stat -c %s -- "$1" 2>/dev/null || stat -f %z -- "$1"; }
has() { [ "$(cat -- "$1" 2>/dev/null)" = "$2" ]; }
gone() { [ ! -e "$1" ] && [ ! -L "$1" ]; }
link_is() { [ -L "$1" ] && [ "$(readlink -- "$1")" = "$2" ]; }
dangling() { [ -L "$1" ] && [ ! -e "$1" ] && [ "$(readlink -- "$1")" = does-not-exist ]; }
empty() { [ -f "$1" ] && [ ! -s "$1" ]; }
nl=$(printf "\nx"); nl=${nl%x}; tb=$(printf "\tx"); tb=${tb%x}; q=$(printf "\047"); u=$(printf "\303\274n\303\257c\303\270d\303\251")
case "$2" in seeded | migrated | changed-dir | changed-volume) : ;; *) echo "dxe-live-check: unknown state $2" >&2; exit 2 ;; esac
chk app-state has "$s/app-state.txt" "$3"
chk fifo test -p "$s/fifo"
if [ "$5" = yes ]; then chk socket test -S "$s/dxe-live.sock"; fi
chk link-to-a link_is "$s/link-to-a" hardlink-a
chk dangling dangling "$s/dangling"
chk link-to-dir link_is "$s/link-to-dir" nested
chk absolute-link link_is "$s/absolute-link" "$s/app-state.txt"
chk private-key-mode test "$(mode "$s/private/key")" = 600
chk private-dir-mode test "$(mode "$s/private")" = 700
chk run-mode test "$(mode "$s/run.sh")" = 755
chk empty-file empty "$s/empty-file"
for o in "with space.txt" "-leading-dash" "tab${tb}name" "quote${q}single" "quote\"double" "back\\slash" "star*glob?" "dollar\$HOME" "$u" "new${nl}line"; do
  chk "odd-name" has "$s/odd names/$o" odd
done
chk bulk-size test "$(size "$blob" 2>/dev/null)" = "$6"
case "$2" in
  seeded | migrated)
    chk hardlink-count test "$(nlink "$s/hardlink-a")" = 3
    chk hardlink-b test "$s/hardlink-a" -ef "$s/hardlink-b"
    chk hardlink-c test "$s/hardlink-a" -ef "$s/nested/hardlink-c"
    chk modified-before has "$s/nested/modified.txt" before
    chk to-delete-present has "$s/nested/to-delete.txt" "to delete"
    chk to-rename-present has "$s/to-rename.txt" "to rename"
    chk dir-to-rename-present has "$s/dir-to-rename/inner/file.txt" inner
    chk not-yet-written gone "$s/written-after-switch.txt" ;;
  *)
    chk hardlink-count test "$(nlink "$s/hardlink-a")" = 2
    chk hardlink-b-deleted gone "$s/hardlink-b"
    chk hardlink-c test "$s/hardlink-a" -ef "$s/nested/hardlink-c"
    chk written has "$s/written-after-switch.txt" "$4"
    chk modified-after has "$s/nested/modified.txt" after
    chk deleted gone "$s/nested/to-delete.txt"
    chk renamed has "$s/renamed.txt" "to rename"
    chk rename-source-gone gone "$s/to-rename.txt"
    chk dir-renamed has "$s/dir-renamed/inner/file.txt" inner
    chk dir-rename-source-gone gone "$s/dir-to-rename" ;;
esac
case "$2" in
  seeded)
    chk apple-top has "$s/._dxe-live-meta" "mac metadata"
    chk apple-deep has "$s/nested/deeper/._deep-meta" "deep mac metadata" ;;
  migrated)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta" ;;
  changed-dir)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta"
    chk apple-new-present has "$s/._rollback-meta" "mac metadata after the switch" ;;
  *)
    chk apple-top-dropped gone "$s/._dxe-live-meta"
    chk apple-deep-dropped gone "$s/nested/deeper/._deep-meta"
    chk apple-new-dropped gone "$s/._rollback-meta" ;;
esac
echo "checks=$n bad=$bad"
[ "$bad" -eq 0 ]'

persist_migrate_live_listing_ok() {
    local last count
    [ -f "$1" ] || return 1
    last="$(sed -n '$p' "$1")"
    count=$(($(wc -l <"$1") - 1))
    [ "$count" -gt 0 ] && [ "$last" = "$(printf 'end\t%s' "$count")" ]
}

persist_migrate_live_records() {
    sed '$d' "$1"
}

persist_migrate_live_records_without_apple() {
    persist_migrate_live_records "$1" | awk -F'\t' 'index($NF, "/._") == 0'
}

# persist_migrate_live_rollback_volume
persist_migrate_live_rollback_volume() {
    if [ -n "${DXE_PERSIST_LIVE_ROLLBACK_VOLUME:-}" ]; then
        printf '%s\n' "$DXE_PERSIST_LIVE_ROLLBACK_VOLUME"
    else
        printf '%s-rollback\n' "${DX_PERSIST_VOLUME:-}"
    fi
}

# persist_migrate_live_bulk_mib
persist_migrate_live_bulk_mib() {
    printf '%s\n' "${DXE_PERSIST_LIVE_BULK_MIB:-$PERSIST_MIGRATE_LIVE_BULK_MIB_DEFAULT}"
}

# persist_migrate_live_volume_name_ok NAME: a canary volume name the suite may
# create, read or delete (dx-..., only lower-case letters, digits and "-").
persist_migrate_live_volume_name_ok() {
    case "$1" in
        dx-*canary*) : ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!abcdefghijklmnopqrstuvwxyz0123456789-]*) return 1 ;;
    esac
    return 0
}

persist_migrate_live_guard() {
    local refused=0 rollback field mib
    persist_live_guard || refused=1
    case "${DX_PERSIST_HOST_ROOT:-}" in
        *,*)
            _persist_live_refuse "DX_PERSIST_HOST_ROOT=${DX_PERSIST_HOST_ROOT:-} holds a comma; the suite's --mount options would split on it."
            refused=1
            ;;
    esac
    rollback="$(persist_migrate_live_rollback_volume)"
    if ! persist_migrate_live_volume_name_ok "$rollback"; then
        _persist_live_refuse "the rollback volume '$rollback' is not a canary volume name (dx-..., containing \"canary\", only [a-z0-9-]); set DXE_PERSIST_LIVE_ROLLBACK_VOLUME or rename DX_PERSIST_VOLUME."
        refused=1
    fi
    for field in DX_NIX_VOLUME DX_PERSIST_VOLUME DX_BOOTSTRAP_VOLUME; do
        if [ "$rollback" = "${!field:-}" ]; then
            _persist_live_refuse "the rollback volume '$rollback' is $field; it must be a new volume no profile setting names."
            refused=1
        fi
    done
    mib="${DXE_PERSIST_LIVE_BULK_MIB:-}"
    case "$mib" in
        '') : ;;
        *[!0-9]* | 0*)
            _persist_live_refuse "DXE_PERSIST_LIVE_BULK_MIB=$mib is not a whole number from 64 to 16384."
            refused=1
            ;;
        *)
            if [ "${#mib}" -gt 5 ] || [ "$mib" -lt 64 ] || [ "$mib" -gt 16384 ]; then
                _persist_live_refuse "DXE_PERSIST_LIVE_BULK_MIB=$mib is not a whole number from 64 to 16384."
                refused=1
            fi
            ;;
    esac
    case "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" in
        '' | "$PERSIST_MIGRATE_LIVE_REAL_GUEST") : ;;
        *)
            _persist_live_refuse "DXE_PERSIST_LIVE_INVENTORY_REAL=${DXE_PERSIST_LIVE_INVENTORY_REAL:-} is not $PERSIST_MIGRATE_LIVE_REAL_GUEST, the only production guest whose inventory the suite may read."
            refused=1
            ;;
    esac
    if [ -n "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" ] && [ "${DXE_PERSIST_LIVE_CLEANUP_ONLY:-}" = 1 ]; then
        _persist_live_refuse "DXE_PERSIST_LIVE_INVENTORY_REAL and DXE_PERSIST_LIVE_CLEANUP_ONLY=1 are separate runs; set one."
        refused=1
    fi
    return "$refused"
}

# persist_migrate_live_dir_read SCRIPT [ARG...]
persist_migrate_live_dir_read() {
    local script="$1" dir
    shift
    dir="$(persist_live_canary_dir)"
    case "$dir" in
        *,*)
            _persist_live_refuse "persist_migrate_live_dir_read: '$dir' holds a comma; no container started."
            return 2
            ;;
    esac
    if ! persist_live_share_path_ok "$dir"; then
        _persist_live_refuse "persist_migrate_live_dir_read: '$dir' is not the canary's own directory; no container started."
        return 2
    fi
    dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0 --pull never \
        --label dxe.role=persist-live --mount "type=bind,source=$dir,target=/canary,readonly" \
        --entrypoint bash "${DX_IMAGE:-}" -c "$script" bash /canary "$@"
}

# persist_migrate_live_volume_read VOLUME SCRIPT [ARG...]
persist_migrate_live_volume_read() {
    local volume="$1" script="$2" rc=0
    shift 2
    if ! persist_migrate_live_volume_name_ok "$volume" || [ "$volume" != "${DX_PERSIST_VOLUME:-}" ] \
        || [ "$volume" = "${DX_NIX_VOLUME:-}" ] || [ "$volume" = "${DX_BOOTSTRAP_VOLUME:-}" ]; then
        _persist_live_refuse "persist_migrate_live_volume_read: '$volume' is not the configured canary persist volume (DX_PERSIST_VOLUME=${DX_PERSIST_VOLUME:-}); no container started."
        return 2
    fi
    case "${DX_IMAGE:-}" in
        *canary*) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_volume_read: DX_IMAGE=${DX_IMAGE:-} is not a canary image; no container started."
            return 2
            ;;
    esac
    dxe_runtime_call dx_runtime_volume_owned "$volume" "read (live suite)" || rc=$?
    [ "$rc" -eq 0 ] || return "$rc"
    dxe_runtime_call dx_runtime_run_ephemeral --rm --network none --user 0:0 --pull never \
        --label dxe.role=persist-live -v "$volume:/v:ro" \
        --entrypoint bash "$DX_IMAGE" -c "$script" bash /v "$@"
}

# persist_migrate_live_interrupt DOCKER_BIN CANON_LEAF DEADLINE
persist_migrate_live_interrupt() {
    local docker_bin="$1" leaf="$2" deadline="$3" why=""
    case "$docker_bin" in
        /*[[:space:]]*) why="the docker CLI path '$docker_bin' holds blanks" ;;
        /*) : ;;
        *) why="the docker CLI path '$docker_bin' is not absolute" ;;
    esac
    case "${DX_IMAGE:-}" in *canary*) : ;; *) why="${why:-DX_IMAGE=${DX_IMAGE:-} is not a canary image}" ;; esac
    persist_migrate_live_volume_name_ok "${DX_PERSIST_VOLUME:-}" || why="${why:-DX_PERSIST_VOLUME=${DX_PERSIST_VOLUME:-} is not a canary volume}"
    persist_live_name_is_canary "${DX_CONTAINER_NAME:-}" || why="${why:-DX_CONTAINER_NAME=${DX_CONTAINER_NAME:-} is not a canary name}"
    case "$leaf" in
        *,*) why="${why:-the destination '$leaf' holds a comma}" ;;
        */dxe/"${DX_CONTAINER_NAME:-}"/persist) persist_live_root_ok "$leaf" || why="${why:-the destination '$leaf' is not a normalised absolute path}" ;;
        *) why="${why:-the destination '$leaf' is not <root>/dxe/${DX_CONTAINER_NAME:-}/persist}" ;;
    esac
    case "$deadline" in
        '' | *[!0-9]* | 0*) why="${why:-the deadline '$deadline' is not a whole number of seconds from 10 to 3600}" ;;
        *) if [ "${#deadline}" -gt 4 ] || [ "$deadline" -lt 10 ] || [ "$deadline" -gt 3600 ]; then
               why="${why:-the deadline '$deadline' is not a whole number of seconds from 10 to 3600}"
           fi ;;
    esac
    if [ -n "$why" ]; then
        _persist_live_refuse "persist_migrate_live_interrupt: $why; nothing was run on the NAS."
        return 2
    fi
    dxe_runtime_call dx_runtime_docker_ssh_exec sh -c "$PERSIST_MIGRATE_LIVE_NAS_SCRIPT_INTERRUPT" dxe-live-interrupt \
        "$docker_bin" "$DX_IMAGE" "$DX_PERSIST_VOLUME" "$leaf" "$PERSIST_MIGRATE_LIVE_BULK" "$PERSIST_MIGRATE_LIVE_BLOB" "$deadline"
}

# persist_migrate_live_real_inventory PROFILE ROOT COMMAND
persist_migrate_live_real_inventory() {
    local profile="$1" root="$2" command="$3"
    case "${command##*/}" in
        dx-persist-inventory) : ;;
        *)
            _persist_live_refuse "persist_migrate_live_real_inventory: '$command' is not dx-persist-inventory; nothing was run."
            return 2
            ;;
    esac
    if [ "${DXE_PERSIST_LIVE_INVENTORY_REAL:-}" != "$PERSIST_MIGRATE_LIVE_REAL_GUEST" ]; then
        _persist_live_refuse "persist_migrate_live_real_inventory: DXE_PERSIST_LIVE_INVENTORY_REAL is not $PERSIST_MIGRATE_LIVE_REAL_GUEST; nothing was run."
        return 2
    fi
    if [ -z "${XDG_STATE_HOME:-}" ]; then
        _persist_live_refuse "persist_migrate_live_real_inventory: XDG_STATE_HOME is not set (the run directory's state); nothing was run."
        return 2
    fi
    (
        # shellcheck disable=SC2030 # this subshell's own resolution root
        DX_PROJECT_ROOT="${BASE_DIR:?}"
        # shellcheck source=../../bin/lib/dx-config.sh
        source "$BASE_DIR/bin/lib/dx-config.sh" >/dev/null 2>&1 || exit 2
        file="$(dx_profile_resolve_file "$profile" 2>/dev/null)" || {
            _persist_live_refuse "persist_migrate_live_real_inventory: no profile '$profile' was found; nothing was run."
            exit 2
        }
        if ! dx_parse_config_file "$file" >/dev/null 2>&1; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' does not parse; nothing was run."
            exit 2
        fi
        if [ "${DXE_PARSED_DX_CONTAINER_NAME:-}" != "$PERSIST_MIGRATE_LIVE_REAL_GUEST" ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' names DX_CONTAINER_NAME=${DXE_PARSED_DX_CONTAINER_NAME:-}, not $PERSIST_MIGRATE_LIVE_REAL_GUEST; nothing was run."
            exit 2
        fi
        if [ "${DXE_PARSED_DX_RUNTIME:-}" != docker-ssh ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' is not a docker-ssh profile; nothing was run."
            exit 2
        fi
        if [ -z "${DXE_PARSED_DX_PERSIST_VOLUME:-}" ]; then
            _persist_live_refuse "persist_migrate_live_real_inventory: the profile '$profile' names no DX_PERSIST_VOLUME; nothing was run."
            exit 2
        fi
        set -- HOME="${HOME:-}" PATH="${PATH:-}" XDG_STATE_HOME="$XDG_STATE_HOME" TMPDIR="${TMPDIR:-/tmp}"
        [ -z "${SSH_AUTH_SOCK:-}" ] || set -- "$@" SSH_AUTH_SOCK="$SSH_AUTH_SOCK"
        for name in $DXE_CONFIG_FIELDS; do
            parsed="DXE_PARSED_$name"
            [ "${!parsed+x}" = x ] || continue
            [ "$name" != DX_PROFILE_ROOT ] || continue
            set -- "$@" "$name=${!parsed}"
        done
        [ "${DXE_PARSED_DX_PERSIST_HOST_ROOT+x}" = x ] || set -- "$@" DX_PERSIST_HOST_ROOT="$root"
        exec env -i "$@" "$command"
    )
}
