#!/usr/bin/env bash
# The /persist migration manifest (plans/do plan.md D-8; spec R33): an
# rsync-independent record of a tree, used to prove a migrated copy (and a
# rollback) equal to its source before anything switches over.
#
#   dx-persist-manifest generate ROOT              manifest of ROOT on stdout
#   dx-persist-manifest compare MANIFEST_A MANIFEST_B
#   dx-persist-manifest verify ROOT_A ROOT_B       generate both, then compare
#
# Exit status follows cmp/diff: 0 equal (or a manifest written), 1 different,
# 2 error or usage. Errors are "Error: ..." lines on stderr, usage errors a
# "Usage:" block; compare and verify print nothing on stdout when they fail.
#
# Two ways to run it, with identical output and status: as a file (`bash
# dx-persist-manifest.sh SUB ...`), or as the inline script of a one-off
# container from the guest image (`bash -c "$TEXT" dx-persist-manifest SUB
# ...`), the way the host runs it on the NAS. Safe to source: functions and
# constants only. Bash 5 with GNU coreutils and findutils (the guest image).
# Every subcommand runs in its own subshell under LC_ALL=C, so the caller's
# locale, options, traps and working directory never matter or change.
#
# Manifest format: one record per entry, ROOT included, each TERMINATED by a
# NUL byte and made of nine TAB-separated fields, in bytewise order of PATH:
#   TYPE MODE OWNER SIZE MTIME SHA256 LINK TARGET PATH
#   TYPE    f d l p s c b, as find's %y prints them
#   MODE    four octal digits, setuid/setgid/sticky included (0644, 1777)
#   OWNER   numeric uid:gid of the entry itself
#   SIZE    bytes for f; "-" otherwise
#   MTIME   the entry's own mtime as SECONDS.NANOSECONDS (nine digits); "-"
#           for ROOT, whose mtime moves whenever its marker is rewritten
#   SHA256  64 lowercase hex digits for f; "-" otherwise
#   LINK    hard-link group: for a non-directory whose inode two or more
#           included entries share, the bytewise-smallest of their PATHs,
#           escaped -- never an inode number, so it is stable across trees;
#           "-" otherwise
#   TARGET  symlink target, escaped; "-" otherwise
#   PATH    "." for ROOT, else "./" + the path below ROOT, raw (any byte but
#           NUL). It is last, so a TAB inside it is unambiguous.
# Escaped means "\" as "\\", TAB as "\t" and newline as "\n". Excluded with
# everything below them: any entry whose name starts with "._" (at any
# depth), and the marker ".dxe-persist-dir" at the top of ROOT (D-3, D-10).
# A read error anywhere fails the whole manifest; a checksum is never guessed.
#
# Cost for large trees: one find walk, sha256sum batched through xargs, one
# sort, and Bash loops that read NUL-terminated records in batches (mapfile),
# with no process per entry. Measured on 208,001 entries in the Linux
# coverage container (2026-10-11): generate about 14 s beyond hashing, compare
# about 28 s; verify of two identical trees skips compare's merge.

# Records per mapfile batch in the Bash loops (bounds their memory use).
DX_MANIFEST_BATCH=4096
# compare prints at most this many difference lines after its summary line.
DX_MANIFEST_MAX_SHOWN=20
# What find prints per entry: nine NUL-terminated chunks, so no field needs
# to be parsed out of a line (PATH and the symlink target may hold any byte).
DX_MANIFEST_WALK_FORMAT='%y\0%m\0%U:%G\0%s\0%T@\0%D:%i\0%n\0%p\0%l\0'
# The names compare reports for the first eight fields, in record order.
DX_MANIFEST_FIELD_NAMES=(type mode owner size mtime sha256 link target)

dx_manifest_error() {
    printf 'Error: %s\n' "$1" >&2
}

dx_manifest_usage() {
    printf '%s\n' 'Usage: dx-persist-manifest generate ROOT' '       dx-persist-manifest compare MANIFEST_A MANIFEST_B' '       dx-persist-manifest verify ROOT_A ROOT_B' >&2
}

# dx_manifest_escape VALUE: sets DX_MANIFEST_ESCAPED to VALUE with each
# backslash doubled, TAB as \t and newline as \n; every other byte as is.
dx_manifest_escape() {
    local bs='\' value
    value=${1//"$bs"/"$bs$bs"}
    value=${value//$'\t'/"${bs}t"}
    DX_MANIFEST_ESCAPED=${value//$'\n'/"${bs}n"}
}

# dx_manifest_tempdir: creates a private temporary directory and prints its
# absolute path (generate changes into ROOT before it uses the directory).
dx_manifest_tempdir() {
    local dir
    dir="$(mktemp -d "${TMPDIR:-/tmp}/dx-persist-manifest.XXXXXXXX")" || return 1
    case "$dir" in
        /*) printf '%s\n' "$dir" ;;
        *) printf '%s/%s\n' "$PWD" "$dir" ;;
    esac
}

# EXIT trap of the generate and verify subshells: removes the files they
# create by name, then the directory itself -- never anything recursively.
_dx_manifest_cleanup() {
    [ -n "${_dxm_tmp:-}" ] || return 0
    rm -f -- "$_dxm_tmp/walk" "$_dxm_tmp/files" "$_dxm_tmp/find.err" "$_dxm_tmp/sums" "$_dxm_tmp/sums.err" "$_dxm_tmp/records" "$_dxm_tmp/a" "$_dxm_tmp/b"
    rmdir -- "$_dxm_tmp" 2>/dev/null
}

# _dx_manifest_relay FILE: each line of a tool's captured stderr as an
# Error: line.
_dx_manifest_relay() {
    local line
    while IFS= read -r line || [ -n "$line" ]; do
        dx_manifest_error "$line"
    done < "$1" # KCOV_LOOP_TERMINATOR
}

# dx_manifest_generate ROOT: the manifest of ROOT on stdout; status 0, or 2
# after Error: lines. Nothing reaches stdout until ROOT has been walked and
# every regular file hashed. Runs in a subshell: it changes into ROOT.
dx_manifest_generate() (
    export LC_ALL=C
    local root="$1" hash_status=0 records_status=0
    dx_manifest_escape "$1"
    local shown="$DX_MANIFEST_ESCAPED"
    # A relative ROOT is entered as ./ROOT: never CDPATH, never "cd -". The
    # temporary directory comes first, while a relative TMPDIR still means
    # what the caller meant.
    case "$root" in
        /*) : ;;
        *) root="./$root" ;;
    esac
    if ! _dxm_tmp="$(dx_manifest_tempdir)"; then
        dx_manifest_error "cannot create a temporary directory under ${TMPDIR:-/tmp}"
        return 2
    fi
    trap _dx_manifest_cleanup EXIT
    if [ -z "$1" ] || [ ! -d "$root" ] || ! cd -P -- "$root" 2>/dev/null; then
        dx_manifest_error "ROOT is not a directory this user can enter: [$shown]"
        return 2
    fi
    # A temporary directory inside ROOT would be walked, and hashed while it
    # is being written: refuse instead of reporting it as a difference.
    case "$(cd -P -- "$_dxm_tmp" && pwd -P)/" in
        "${PWD%/}/"*)
            dx_manifest_error "the temporary directory [$_dxm_tmp] is inside ROOT [$shown]; point TMPDIR outside it"
            return 2
            ;;
    esac
    # Walk from "." so find prints PATH exactly as the record wants it, and
    # the top-level marker is the literal path ./.dxe-persist-dir.
    if ! find . \( -name '._*' -o -path ./.dxe-persist-dir \) -prune -o -printf "$DX_MANIFEST_WALK_FORMAT" -type f -fprint0 "$_dxm_tmp/files" > "$_dxm_tmp/walk" 2> "$_dxm_tmp/find.err"; then
        _dx_manifest_relay "$_dxm_tmp/find.err"
        dx_manifest_error "cannot walk ROOT [$shown]; no manifest written"
        return 2
    fi
    # Same order as the walk; -r: with no regular file, sha256sum never runs
    # (it would hash its stdin).
    xargs -0 -r sha256sum -z -- < "$_dxm_tmp/files" > "$_dxm_tmp/sums" 2> "$_dxm_tmp/sums.err" || hash_status=$?
    _dx_manifest_records "$_dxm_tmp/walk" "$_dxm_tmp/sums" > "$_dxm_tmp/records" || records_status=$?
    if [ "$hash_status" -ne 0 ] || [ "$records_status" -ne 0 ]; then
        _dx_manifest_relay "$_dxm_tmp/sums.err"
        dx_manifest_error "cannot checksum every regular file under ROOT [$shown]; no manifest written"
        return 2
    fi
    if ! sort -z -t $'\t' -k9 -- "$_dxm_tmp/records"; then
        dx_manifest_error "cannot sort the manifest of ROOT [$shown]"
        return 2
    fi
) # KCOV_SUBSHELL_TERMINATOR

# _dx_manifest_records WALK SUMS: one record per walked entry on stdout, in
# walk order. WALK holds find's nine chunks per entry; SUMS holds sha256sum
# -z output for the walk's regular files, in the same order. Returns 1 after
# an Error: line for every regular file without its checksum.
_dx_manifest_records() {
    local t=$'\t' walk_fd i path type mode owner size mtime fraction sum target key j link status=0
    local -a chunks out=() deferred_key=() deferred_head=() deferred_tail=()
    local -A first=() members=()
    local _dxm_sum_fd _dxm_sum_pos=0
    local -a _dxm_sums=()
    exec {walk_fd}< "$1" {_dxm_sum_fd}< "$2"
    while mapfile -t -d '' -n "$((DX_MANIFEST_BATCH * 9))" -u "$walk_fd" chunks && [ "${#chunks[@]}" -gt 0 ]; do
        out=()
        for ((i = 0; i < ${#chunks[@]}; i += 9)); do
            type=${chunks[i]}
            mode=000${chunks[i + 1]}
            mode=${mode: -4}
            owner=${chunks[i + 2]}
            path=${chunks[i + 7]}
            mtime=${chunks[i + 4]}
            [[ $mtime == *.* ]] || mtime=$mtime.
            fraction=${mtime#*.}000000000
            mtime=${mtime%%.*}.${fraction:0:9}
            [ "$path" != . ] || mtime=-
            size=- sum=- target=-
            case "$type" in
                f)
                    size=${chunks[i + 3]}
                    if _dx_manifest_take_sum "$path"; then
                        sum=$DX_MANIFEST_SUM
                    else
                        dx_manifest_escape "$path"
                        dx_manifest_error "cannot read $DX_MANIFEST_ESCAPED: no checksum"
                        status=1
                    fi
                    ;;
                l)
                    dx_manifest_escape "${chunks[i + 8]}"
                    target=$DX_MANIFEST_ESCAPED
                    ;;
                *) : ;;
            esac
            # A non-directory with more than one link may share its inode with
            # other entries; its group id is known only once the walk is done.
            if [ "$type" != d ] && [ "${chunks[i + 6]}" -gt 1 ]; then
                key=${chunks[i + 5]}
                if [ -z "${first[$key]+set}" ] || [[ $path < ${first[$key]} ]]; then
                    first[$key]=$path
                fi
                members[$key]=$((${members[$key]:-0} + 1))
                deferred_key+=("$key")
                deferred_head+=("$type$t$mode$t$owner$t$size$t$mtime$t$sum")
                deferred_tail+=("$target$t$path")
            else
                out+=("$type$t$mode$t$owner$t$size$t$mtime$t$sum$t-$t$target$t$path")
            fi
        done
        [ "${#out[@]}" -eq 0 ] || printf '%s\0' "${out[@]}"
    done
    out=()
    for ((j = 0; j < ${#deferred_key[@]}; j++)); do
        key=${deferred_key[j]}
        link=-
        if [ "${members[$key]}" -gt 1 ]; then
            dx_manifest_escape "${first[$key]}"
            link=$DX_MANIFEST_ESCAPED
        fi
        out+=("${deferred_head[j]}$t$link$t${deferred_tail[j]}")
    done
    [ "${#out[@]}" -eq 0 ] || printf '%s\0' "${out[@]}"
    exec {walk_fd}<&- {_dxm_sum_fd}<&-
    return "$status"
}

# _dx_manifest_take_sum PATH: sets DX_MANIFEST_SUM to PATH's checksum when it
# is the next one in the sums stream, and consumes it; returns 1 (consuming
# nothing) when it is not -- sha256sum skipped PATH because it failed on it.
_dx_manifest_take_sum() {
    local entry
    if [ "$_dxm_sum_pos" -ge "${#_dxm_sums[@]}" ]; then
        mapfile -t -d '' -n "$DX_MANIFEST_BATCH" -u "$_dxm_sum_fd" _dxm_sums
        _dxm_sum_pos=0
    fi
    entry=${_dxm_sums[_dxm_sum_pos]-}
    [ "${entry:64:2}" = "  " ] && [ "${entry:66}" = "$1" ] && [[ ${entry:0:64} != *[!0-9a-f]* ]] || return 1
    DX_MANIFEST_SUM=${entry:0:64}
    _dxm_sum_pos=$((_dxm_sum_pos + 1))
}

# dx_manifest_compare MANIFEST_A MANIFEST_B: A is the source, B the
# destination. Prints "Manifests match: entries=N" (status 0), or
# "Manifests differ: differences=D entries-a=NA entries-b=NB" and the first
# DX_MANIFEST_MAX_SHOWN of the D difference lines (status 1), one per PATH in
# bytewise order: "missing PATH" (A only), "extra PATH" (B only) or
# "changed FIELDS PATH". Status 2, with nothing on stdout, for a manifest that
# cannot be read or is malformed: no records, a first record that is not
# ROOT's, a record with fewer than nine fields, or PATHs out of bytewise
# order (or repeated), which a merge by PATH could not trust.
dx_manifest_compare() (
    export LC_ALL=C
    local differences=0
    local -a shown=()
    # Per-side reader state, reached through namerefs in _dx_manifest_advance.
    local _dxm_name_a="$1" _dxm_fd_a='' _dxm_pos_a=0 _dxm_count_a=0 _dxm_more_a=0 _dxm_path_a='' _dxm_head_a=''
    local _dxm_name_b="$2" _dxm_fd_b='' _dxm_pos_b=0 _dxm_count_b=0 _dxm_more_b=0 _dxm_path_b='' _dxm_head_b=''
    local -a _dxm_buf_a=() _dxm_buf_b=()
    local _dxm_split_record=
    _dx_manifest_open a && _dx_manifest_open b || return 2
    while [ "$_dxm_more_a" = 1 ] || [ "$_dxm_more_b" = 1 ]; do
        if [ "$_dxm_more_a" = 1 ] && [ "$_dxm_more_b" = 1 ] && [ "$_dxm_path_a" = "$_dxm_path_b" ]; then
            if [ "$_dxm_head_a" != "$_dxm_head_b" ]; then
                _dx_manifest_changed "$_dxm_head_a" "$_dxm_head_b"
                _dx_manifest_note "changed $DX_MANIFEST_CHANGED" "$_dxm_path_a"
            fi
            _dx_manifest_advance a && _dx_manifest_advance b || return 2
        elif [ "$_dxm_more_b" != 1 ] || { [ "$_dxm_more_a" = 1 ] && [[ $_dxm_path_a < $_dxm_path_b ]]; }; then
            _dx_manifest_note missing "$_dxm_path_a"
            _dx_manifest_advance a || return 2
        else
            _dx_manifest_note extra "$_dxm_path_b"
            _dx_manifest_advance b || return 2
        fi
    done
    if [ "$differences" -eq 0 ]; then
        printf 'Manifests match: entries=%s\n' "$_dxm_count_a"
        return 0
    fi
    printf 'Manifests differ: differences=%s entries-a=%s entries-b=%s\n' "$differences" "$_dxm_count_a" "$_dxm_count_b"
    printf '%s\n' "${shown[@]}"
    return 1
) # KCOV_SUBSHELL_TERMINATOR

# _dx_manifest_open SIDE: opens manifest SIDE (a or b) and reads its first
# record, which must be ROOT's.
_dx_manifest_open() {
    local -n name="_dxm_name_$1" fd="_dxm_fd_$1" more="_dxm_more_$1"
    local opened
    dx_manifest_escape "$name"
    if [ -d "$name" ] || [ ! -r "$name" ] || ! { exec {opened}< "$name"; } 2>/dev/null; then
        dx_manifest_error "cannot read manifest [$DX_MANIFEST_ESCAPED]"
        return 1
    fi
    fd=$opened
    _dx_manifest_advance "$1" || return 1
    if [ "$more" != 1 ]; then
        dx_manifest_error "malformed manifest [$DX_MANIFEST_ESCAPED]: no records"
        return 1
    fi
}

# _dx_manifest_advance SIDE: moves SIDE to its next record, setting its
# path, head (the first eight fields) and record count, or more=0 at its
# end. Returns 1 after an Error: line when the record is malformed.
_dx_manifest_advance() {
    local -n name="_dxm_name_$1" fd="_dxm_fd_$1" buf="_dxm_buf_$1" pos="_dxm_pos_$1" count="_dxm_count_$1" more="_dxm_more_$1" path="_dxm_path_$1" head="_dxm_head_$1"
    local previous="$path" problem=
    if [ "$pos" -ge "${#buf[@]}" ]; then
        mapfile -t -d '' -n "$DX_MANIFEST_BATCH" -u "$fd" buf
        pos=0
        if [ "${#buf[@]}" -eq 0 ]; then
            more=0
            return 0
        fi
    fi
    count=$((count + 1))
    if ! _dx_manifest_split "${buf[pos]}"; then
        problem="record $count is not nine TAB-separated fields (eight non-empty ones, then PATH)"
    elif [ "$count" -eq 1 ] && [ "$DX_MANIFEST_PATH" != . ]; then
        problem="the first record is not the ROOT record \".\""
    elif [ "$count" -gt 1 ] && ! [[ $previous < $DX_MANIFEST_PATH ]]; then
        problem="record $count is not in bytewise PATH order (or repeats a PATH)"
    fi
    if [ -n "$problem" ]; then
        dx_manifest_escape "$name"
        dx_manifest_error "malformed manifest [$DX_MANIFEST_ESCAPED]: $problem"
        return 1
    fi
    pos=$((pos + 1))
    more=1
    path=$DX_MANIFEST_PATH
    # shellcheck disable=SC2034  # a nameref: this sets _dxm_head_a or _dxm_head_b
    head=$DX_MANIFEST_HEAD
}

# _dx_manifest_split RECORD: sets DX_MANIFEST_HEAD (the first eight fields,
# TAB-joined) and DX_MANIFEST_PATH (everything after the eighth TAB). Returns
# 1 unless RECORD is eight non-empty TAB-free fields and a non-empty PATH (as
# generate writes them). Splitting on TAB as IFS whitespace is linear, unlike
# peeling one field at a time with pattern removal; the prefix check catches
# the empty fields that whitespace splitting would merge. A record equal to
# the previous one (the common case: B's record after A's in equal trees) is
# not split again.
_dx_manifest_split() {
    if [ -n "$1" ] && [ "$1" = "$_dxm_split_record" ]; then
        return 0
    fi
    _dxm_split_record=
    local - IFS=$'\t' fields
    set -f
    # shellcheck disable=SC2206  # deliberate TAB splitting, globbing off
    fields=($1)
    [ "${#fields[@]}" -ge 9 ] || return 1
    DX_MANIFEST_HEAD="${fields[*]:0:8}"
    [ "${1:0:${#DX_MANIFEST_HEAD}+1}" = "$DX_MANIFEST_HEAD$IFS" ] || return 1
    DX_MANIFEST_PATH=${1:${#DX_MANIFEST_HEAD}+1}
    _dxm_split_record=$1
}

# _dx_manifest_changed HEAD_A HEAD_B: sets DX_MANIFEST_CHANGED to the names
# of the fields that differ, in record order, comma-separated. Both heads are
# eight non-empty fields (_dx_manifest_split checked them).
_dx_manifest_changed() {
    local - IFS=$'\t' fields_a fields_b k changed=
    set -f
    # shellcheck disable=SC2206  # deliberate TAB splitting, globbing off
    fields_a=($1)
    # shellcheck disable=SC2206  # deliberate TAB splitting, globbing off
    fields_b=($2)
    for ((k = 0; k < 8; k++)); do
        [ "${fields_a[k]}" = "${fields_b[k]}" ] || changed="$changed,${DX_MANIFEST_FIELD_NAMES[k]}"
    done
    DX_MANIFEST_CHANGED=${changed#,}
}

# _dx_manifest_note KIND PATH: counts one difference and keeps its line while
# fewer than DX_MANIFEST_MAX_SHOWN are kept.
_dx_manifest_note() {
    differences=$((differences + 1))
    [ "$differences" -le "$DX_MANIFEST_MAX_SHOWN" ] || return 0
    dx_manifest_escape "$2"
    shown+=("$1 $DX_MANIFEST_ESCAPED")
}

# dx_manifest_verify ROOT_A ROOT_B: generates both manifests (A first; a
# failure stops before B is hashed), then prints and returns exactly what
# compare does. Status 2 if either generate fails.
dx_manifest_verify() (
    export LC_ALL=C
    set -o pipefail
    local digest_a digest_b entries
    if ! _dxm_tmp="$(dx_manifest_tempdir)"; then
        dx_manifest_error "cannot create a temporary directory under ${TMPDIR:-/tmp}"
        return 2
    fi
    trap _dx_manifest_cleanup EXIT
    dx_manifest_generate "$1" > "$_dxm_tmp/a" || return 2
    dx_manifest_generate "$2" > "$_dxm_tmp/b" || return 2
    # Identical manifests that generate itself wrote are well-formed and
    # equal: say so as compare would, without its record-by-record merge (the
    # slow part for a large tree). Any failure here falls through to compare.
    if digest_a="$(sha256sum < "$_dxm_tmp/a")" && digest_b="$(sha256sum < "$_dxm_tmp/b")" && [ "$digest_a" = "$digest_b" ] && entries="$(tr -cd '\0' < "$_dxm_tmp/a" | wc -c)" && [ "$entries" -gt 0 ]; then
        printf 'Manifests match: entries=%s\n' "$entries"
        return 0
    fi
    dx_manifest_compare "$_dxm_tmp/a" "$_dxm_tmp/b"
) # KCOV_SUBSHELL_TERMINATOR

dx_manifest_main() {
    case "${1-}:$#" in
        generate:2) dx_manifest_generate "$2" ;;
        compare:3) dx_manifest_compare "$2" "$3" ;;
        verify:3) dx_manifest_verify "$2" "$3" ;;
        *)
            dx_manifest_usage
            return 2
            ;;
    esac
}

# Run as a file, or as `bash -c "$TEXT" dx-persist-manifest ...`, where no
# file backs the text (BASH_SOURCE is empty) and $0 is the tool's name.
if [ "${BASH_SOURCE[0]-}" = "$0" ] || { [ "${#BASH_SOURCE[@]}" -eq 0 ] && [ "$0" = dx-persist-manifest ]; }; then
    dx_manifest_main "$@"
fi
