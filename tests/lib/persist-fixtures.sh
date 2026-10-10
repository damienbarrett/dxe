#!/bin/bash
# Shared /persist host-access fixtures (WP0.2). Safe to source: functions and
# constants only; no output, shell options, cwd change or I/O at import time.
# Bash 3.2 compatible. Needs only perl (sockets, sorting) beyond coreutils.

_PERSIST_FIXTURES_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=fake-tools.sh
source "$_PERSIST_FIXTURES_DIR/fake-tools.sh"

# shellcheck disable=SC2034  # consumed by the sourcing suites
PERSIST_FIXTURE_NAS_HOST="dxe-fixture-nas.invalid"

# persist_fixture_root_create [PARENT]: new empty share root; prints its path.
persist_fixture_root_create() {
    mktemp -d "${1:-${TMPDIR:-/tmp}}/dxe-persist-share.XXXXXX"
}

# persist_fixture_cleanup PATH...: remove fixture trees, refusing anything
# that is not clearly a dxe- fixture path.
persist_fixture_cleanup() {
    local target base
    for target in "$@"; do
        base="${target##*/}"
        case "$target" in
            "" | "/" | ".") base="" ;;
        esac
        case "$base" in
            dxe-*) : ;;
            *)
                echo "persist-fixtures: refusing to remove [$target]" >&2
                return 1
                ;;
        esac
    done
    for target in "$@"; do
        [ -e "$target" ] || [ -L "$target" ] || continue
        chmod -R u+rwx "$target" 2>/dev/null || true
        rm -rf "$target"
    done
}

# persist_fixture_nas_create ROOT [PARENT]: fake tool dir whose ssh runs the
# remote command locally with cwd = ROOT.
persist_fixture_nas_create() {
    local root="$1" parent="${2:-${TMPDIR:-/tmp}}" tools
    if [ ! -d "$root" ]; then
        echo "persist-fixtures: share root $root does not exist" >&2
        return 1
    fi
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
persist_fixture_tree_build() {
    local dir="$1"
    if [ ! -d "$dir" ]; then
        echo "persist-fixtures: directory $dir does not exist" >&2
        return 1
    fi
    (
        cd "$dir" || exit 1
        mkdir -p private-0700 nested/a/b/c links special names
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
        (cd special && perl -MIO::Socket::UNIX -e \
            'IO::Socket::UNIX->new(Local => "sock", Listen => 1) or die "socket: $!\n"') || exit 1
        mkfifo special/fifo
        printf 'x' > "names/line
break.txt"
        : > names/-dash.txt
        : > "names/with space.txt"
        if [ "$(persist_fixture_euid)" = 0 ]; then
            mkdir owners
            : > owners/uid30033
            chown 30033:30033 "$dir/owners/uid30033"
            : > owners/uid0
            chown 0:0 "$dir/owners/uid0"
            mkdir owners/dir30033
            chown 30033:30033 "$dir/owners/dir30033"
        fi
        find . -type d -exec chmod 0755 {} +
        find . -type f -exec chmod 0644 {} +
        chmod 0600 secret-0600.txt
        chmod 0700 private-0700
    )
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
