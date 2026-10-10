#!/bin/bash
# Shared /persist host-access fixtures (WP0.2). Safe to source: functions and
# constants only; no output, shell options, cwd change or I/O at import time.
# Bash 3.2 compatible. Needs only perl (sockets, sorting, the account home)
# beyond coreutils.
#
# The contract is pinned by tests/test_persist_fixtures.sh and, for the safety
# rules (which win where the two differ), tests/test_persist_fixtures_safety.sh.

_PERSIST_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fake-tools.sh
source "$_PERSIST_FIXTURES_DIR/fake-tools.sh"

# shellcheck disable=SC2034  # consumed by the sourcing suites
PERSIST_FIXTURE_NAS_HOST="dxe-fixture-nas.invalid"

# persist_fixture_root_create [PARENT]: new empty share root; prints its path.
persist_fixture_root_create() {
    mktemp -d "${1:-${TMPDIR:-/tmp}}/dxe-persist-share.XXXXXX"
}

# persist_fixture_cleanup PATH...: remove fixture trees. Every PATH is
# checked before anything is touched, and one refused PATH refuses the whole
# call: it must be absolute, its basename must start with dxe- (so "", "/"
# and a trailing "/" are refused) and its parent directory, resolved
# physically, must be the temp area (see _persist_fixture_temp_area) or lie
# below it. A symlink PATH is unlinked, never followed. Otherwise only
# directories get u+rwx before the rm -rf: a recursive chmod would also
# reach files that are hard links to inodes outside the temp area. rm, chmod
# and find are found through PATH, so tests can put recording stubs in front.
persist_fixture_cleanup() {
    local area target
    area="$(_persist_fixture_temp_area)" || area=""
    for target in "$@"; do
        if ! _persist_fixture_cleanup_allowed "$area" "$target"; then
            echo "persist-fixtures: refusing to remove [$target]: not an absolute dxe- path inside the temp area [${TMPDIR:-/tmp}]" >&2
            return 1
        fi
    done
    for target in "$@"; do
        if [ -L "$target" ]; then
            rm -f -- "$target"
        elif [ -e "$target" ]; then
            find -P "$target" -type d -exec chmod u+rwx {} \; 2>/dev/null || true
            rm -rf -- "$target"
        fi
    done
}

# _persist_fixture_cleanup_allowed AREA PATH: AREA is the temp area as
# _persist_fixture_temp_area prints it ("" when there is none).
_persist_fixture_cleanup_allowed() {
    local area="$1" target="$2" parent
    [ -n "$area" ] || return 1
    case "$target" in
        /*) : ;;
        *) return 1 ;;
    esac
    case "${target##*/}" in
        dxe-*) : ;;
        *) return 1 ;;
    esac
    parent="${target%/*}"
    parent="$(_persist_fixture_physical_dir "${parent:-/}")" || return 1
    # Both end in "/", so a sibling such as "$TMPDIR-evil" does not match.
    case "$parent" in
        "$area"*) return 0 ;;
    esac
    return 1
}

# _persist_fixture_temp_area: prints ${TMPDIR:-/tmp} as
# _persist_fixture_physical_dir does. Fails -- there is no temp area -- when
# it does not resolve, is the root directory (however spelled, e.g. "//"),
# or is or contains the account home (the passwd entry of the effective uid,
# not $HOME, which suites isolate under the temp area) or the checkout this
# library belongs to.
_persist_fixture_temp_area() {
    local area home checkout
    area="$(_persist_fixture_physical_dir "${TMPDIR:-/tmp}")" || return 1
    [ ! "$area" -ef / ] || return 1
    home="$(perl -e 'my $h = (getpwuid($>))[7]; print $h if defined $h' 2>/dev/null)"
    if [ -n "$home" ] && home="$(_persist_fixture_physical_dir "$home")"; then
        case "$home" in
            "$area"*) return 1 ;;
        esac
    fi
    checkout="$(_persist_fixture_physical_dir "$_PERSIST_FIXTURES_DIR/../..")" || return 1
    case "$checkout" in
        "$area"*) return 1 ;;
    esac
    printf '%s' "$area"
}

# _persist_fixture_physical_dir DIR: prints DIR resolved physically, as
# `cd -P -- DIR && pwd -P` would, plus a trailing "/" so a name ending in a
# newline survives command substitution; fails when DIR cannot be entered.
# A relative DIR is entered as "./DIR", so neither CDPATH nor a DIR of "-"
# ($OLDPWD) applies, and only while $PWD names the real cwd: bash resolves
# it from the $PWD string, which is stale once the cwd's symlink has been
# repointed.
_persist_fixture_physical_dir() {
    local dir="$1"
    case "$dir" in
        /*) : ;;
        *)
            [ "$PWD" -ef . ] || return 1
            dir="./$dir"
            ;;
    esac
    (cd -P -- "$dir" >/dev/null 2>&1 && printf '%s/' "${PWD%/}")
}

# persist_fixture_nas_create ROOT [PARENT]: fake tool dir whose ssh runs the
# remote command locally with cwd = ROOT. A relative ROOT is stored as its
# absolute physical path, so the fake works from any cwd.
persist_fixture_nas_create() {
    local root="$1" parent="${2:-${TMPDIR:-/tmp}}" tools
    if [ ! -d "$root" ]; then
        echo "persist-fixtures: share root $root does not exist" >&2
        return 1
    fi
    case "$root" in
        /*) : ;;
        *)
            if ! root="$(_persist_fixture_physical_dir "$root")"; then
                echo "persist-fixtures: share root $1 cannot be resolved from the current directory" >&2
                return 1
            fi
            [ "$root" = / ] || root="${root%/}"
            ;;
    esac
    tools="$(fake_tool_dir_create "$parent")" || return 1
    fake_qnap_ssh_write "$tools"
    mv "$tools/ssh" "$tools/.ssh-inner"
    fake_tool_write "$tools" ssh "$(printf 'cd %q || exit 1\nDXE_FIXTURE_NAS_ROOT=%q\nexport DXE_FIXTURE_NAS_ROOT\nexec %q "$@"' \
        "$root" "$root" "$tools/.ssh-inner")"
    printf '%s\n' "$tools"
}

persist_fixture_euid() {
    id -u
}

# persist_fixture_tree_build DIR: populate DIR with the pinned fixture tree.
# DIR must lie strictly inside the temp area. The builder enters it with cd
# and creates everything relative to it; it refuses a DIR that already holds
# one of the names it creates, so it sets modes only on entries it made.
persist_fixture_tree_build() {
    local dir="$1" phys owners name
    if [ ! -d "$dir" ]; then
        echo "persist-fixtures: directory $dir does not exist" >&2
        return 1
    fi
    if ! phys="$(_persist_fixture_build_dir "$dir")"; then
        echo "persist-fixtures: refusing to build in [$dir]: not a directory inside the temp area [${TMPDIR:-/tmp}]" >&2
        return 1
    fi
    # chown's argv names the owners entries as "$DIR/owners/..." (pinned);
    # a relative DIR is the cwd once the builder has entered it.
    case "$dir" in
        /*) owners="$dir/owners" ;;
        *) owners=owners ;;
    esac
    (
        cd -P -- "$phys" || exit 1
        # The check-then-act window: DIR was validated before this cd, so a
        # component swapped for a symlink since would land elsewhere. Refuse
        # unless the physical cwd is the very path that was validated.
        if [ "${PWD%/}/" != "$phys" ]; then
            echo "persist-fixtures: refusing to build in [$dir]: it is no longer the directory that was validated" >&2
            exit 1
        fi
        for name in plain.txt empty-file secret-0600.txt private-0700 ._root-meta nested links special names owners; do
            if [ -e "$name" ] || [ -L "$name" ]; then
                echo "persist-fixtures: refusing to build in [$dir]: it already holds $name" >&2
                exit 1
            fi
        done
        mkdir private-0700 nested nested/a nested/a/b nested/a/b/c links special names
        printf 'plain\n' > plain.txt
        : > empty-file
        printf 'secret\n' > secret-0600.txt
        printf 'inner\n' > private-0700/inner.txt
        : > ._root-meta
        printf 'deep\n' > nested/a/b/c/deep.txt
        : > nested/a/._deep-meta
        printf 'group-a\n' > links/a-one
        ln links/a-one links/a-two
        ln links/a-one nested/a/a-three
        printf 'group-b\n' > links/b-one
        ln links/b-one nested/b-two
        ln -s ../plain.txt links/to-plain
        ln -s no-such-target links/dangling
        (cd ./special && perl -MIO::Socket::UNIX -e \
            'IO::Socket::UNIX->new(Local => "sock", Listen => 1) or die "socket: $!\n"') || exit 1
        mkfifo special/fifo
        printf 'x' > "names/line
break.txt"
        : > names/-dash.txt
        : > "names/with space.txt"
        chmod 0755 nested nested/a nested/a/b nested/a/b/c links special names
        chmod 0700 private-0700
        chmod 0644 plain.txt empty-file private-0700/inner.txt ._root-meta nested/a/b/c/deep.txt \
            nested/a/._deep-meta links/a-one links/b-one "names/line
break.txt" names/-dash.txt "names/with space.txt"
        chmod 0600 secret-0600.txt
        if [ "$(persist_fixture_euid)" = 0 ]; then
            mkdir owners
            : > owners/uid30033
            : > owners/uid0
            mkdir owners/dir30033
            chmod 0755 owners owners/dir30033
            chmod 0644 owners/uid30033 owners/uid0
            chown 30033:30033 "$owners/uid30033"
            chown 0:0 "$owners/uid0"
            chown 30033:30033 "$owners/dir30033"
        fi
    )
}

# _persist_fixture_build_dir DIR: prints DIR as _persist_fixture_physical_dir
# does when it lies strictly inside the temp area (not the area itself);
# fails otherwise.
_persist_fixture_build_dir() {
    local area phys
    area="$(_persist_fixture_temp_area)" || return 1
    phys="$(_persist_fixture_physical_dir "$1")" || return 1
    case "$phys" in
        "$area"?*) printf '%s' "$phys" ;;
        *) return 1 ;;
    esac
}

# persist_fixture_tree_list DIR: NUL-terminated relative paths, bytewise sorted.
persist_fixture_tree_list() {
    perl -e '
        my @out;
        sub walk {
            my ($abs, $rel) = @_;
            opendir(my $dh, $abs) or return;
            my @names = grep { $_ ne "." && $_ ne ".." } readdir($dh);
            closedir($dh);
            for my $n (@names) {
                my $r = length($rel) ? "$rel/$n" : $n;
                push @out, $r;
                walk("$abs/$n", $r) if -d "$abs/$n" && !-l "$abs/$n";
            }
        }
        walk($ARGV[0], "");
        print map { "$_\0" } sort @out;' "$1"
}
