#!/bin/bash
set -uo pipefail
# Increment 1 (Branch 10, feat/persist-backup): the /persist backup selection
# rules, exercised as a pure, sourceable function set against fixture trees.
# No container: every fixture here is a plain directory tree with real git
# repositories, standing in for /persist.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
GUEST="$BASE_DIR/container/aarch64-darwin-apple-container-dx-nixos-26.05"
SELECTOR="$GUEST/scripts/lib/dx-persist-backup-select.sh"
# shellcheck source=../container/aarch64-darwin-apple-container-dx-nixos-26.05/scripts/lib/dx-persist-backup-select.sh
source "$SELECTOR"
test_section "Persist backup: selection rules (fixture trees, no container)"

FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-test.XXXXXX")"
trap 'chmod -R u+w "$FIXTURE" 2>/dev/null || true; rm -rf "$FIXTURE"' EXIT

git_repo() {
    local repo="$1"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email test@example.com
    git -C "$repo" config user.name "DXE Test"
}

# ShellCheck's SC2218 ("this function is only defined later") cannot see
# execution order: this file repeatedly builds a git fixture with the REAL
# git binary, then locally shadows `git` for one target substring only
# (falling through to `command git "$@"` for everything else), then
# `unset -f git` immediately after the assertion that needed it. Every git
# invocation marked `# shellcheck disable=SC2218` below runs strictly
# BEFORE its own block's shadow definition is ever executed, so it is
# always the real git -- moving a shadow definition earlier would make it
# intercept the very fixture-building calls it needs to run for real first
# (and, for the single-target shadows, an unset "$..._target" degrades
# their case pattern to *"$empty"* == **, which matches every invocation).

# --- Fixture: repo-a -- has a remote, HEAD is pushed, then gains local,
# uncommitted changes of every kind the rules must catch. ---
mkdir -p "$FIXTURE/remotes"
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-a.git"
git_repo "$FIXTURE/persist/git/repo-a"
printf 'unchanged\n' > "$FIXTURE/persist/git/repo-a/unchanged.txt"
printf 'original\n' > "$FIXTURE/persist/git/repo-a/modified.txt"
mkdir -p "$FIXTURE/persist/git/repo-a/node_modules/pkg"
printf 'dep\n' > "$FIXTURE/persist/git/repo-a/node_modules/pkg/index.js"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" commit -q -m "initial"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" remote add origin "$FIXTURE/remotes/repo-a.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" push -q origin main
# Now make it dirty in every way the rules must catch.
printf 'changed\n' > "$FIXTURE/persist/git/repo-a/modified.txt"
printf 'brand new\n' > "$FIXTURE/persist/git/repo-a/staged-new.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" add staged-new.txt
printf 'untracked\n' > "$FIXTURE/persist/git/repo-a/untracked.txt"
printf 'secret.local\n' > "$FIXTURE/persist/git/repo-a/.gitignore"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-a" add .gitignore
printf 'do-not-lose-me\n' > "$FIXTURE/persist/git/repo-a/secret.local"
printf 'rebuildable\n' > "$FIXTURE/persist/git/repo-a/node_modules/pkg/new-dep.js"

# --- Fixture: repo-b -- pushed once, then a LOCAL-ONLY commit on top: the
# whole repository (including .git) must be treated as at-risk. ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-b.git"
git_repo "$FIXTURE/persist/git/repo-b"
printf 'one\n' > "$FIXTURE/persist/git/repo-b/file.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-b" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-b" commit -q -m "initial"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-b" remote add origin "$FIXTURE/remotes/repo-b.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-b" push -q origin main
printf 'two\n' >> "$FIXTURE/persist/git/repo-b/file.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-b" commit -q -am "local-only commit"

# --- Fixture: repo-c -- no remote at all: at-risk as a whole even though
# everything is committed and the tree is otherwise clean. ---
git_repo "$FIXTURE/persist/git/repo-c"
printf 'clean\n' > "$FIXTURE/persist/git/repo-c/clean.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-c" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-c" commit -q -m "only commit, no remote"

# --- Fixture: repo-detached -- WP6.2 / Astra F2: a commit reachable ONLY
# from a DETACHED HEAD, with an otherwise fully-pushed branch, must be
# classified at-risk-whole. Before the fix, `git log --branches --not
# --remotes` never looked at HEAD at all when it was detached, so this
# reproduced live as "safe" -- zero backup entries for a real local-only
# commit. ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-detached.git"
git_repo "$FIXTURE/persist/git/repo-detached"
printf 'pushed\n' > "$FIXTURE/persist/git/repo-detached/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" commit -q -m "pushed commit"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" remote add origin "$FIXTURE/remotes/repo-detached.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" push -q origin main
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" checkout -q --detach main
printf 'pushed\nlocal-only change\n' > "$FIXTURE/persist/git/repo-detached/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-detached" commit -q -am "local-only commit on detached HEAD"

# --- Fixture: repo-stash -- WP6.2: stash-only work (everything else
# pushed and clean) must be retained. A stash commit is reachable only
# from refs/stash, never from a branch or tag, so it needs its own
# explicit reachability check -- see the retention-policy comment above
# dx_pbs_repo_at_risk_whole. ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-stash.git"
git_repo "$FIXTURE/persist/git/repo-stash"
printf 'pushed\n' > "$FIXTURE/persist/git/repo-stash/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-stash" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-stash" commit -q -m "pushed commit"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-stash" remote add origin "$FIXTURE/remotes/repo-stash.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-stash" push -q origin main
printf 'pushed\nstashed change\n' > "$FIXTURE/persist/git/repo-stash/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-stash" stash push -q -m "wip"

# --- Fixture: repo-tag-local -- WP6.2: a local-only tag pointing at a
# commit ALREADY reachable from a remote-tracking ref is NOT at-risk (the
# retention policy documented above dx_pbs_repo_at_risk_whole): the
# commit's content is already safely on the remote, and only the tag
# POINTER itself is local. ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-tag-local.git"
git_repo "$FIXTURE/persist/git/repo-tag-local"
printf 'pushed\n' > "$FIXTURE/persist/git/repo-tag-local/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-local" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-local" commit -q -m "pushed commit"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-local" remote add origin "$FIXTURE/remotes/repo-tag-local.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-local" push -q origin main
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-local" tag local-only-tag main

# --- Fixture: repo-tag-unpushed -- WP6.2: a local tag on a commit that is
# NOT reachable from any remote -- even after no branch points there any
# more -- still flags the repository at-risk: the tag alone keeps that
# commit's content the operator's sole responsibility to protect. ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-tag-unpushed.git"
git_repo "$FIXTURE/persist/git/repo-tag-unpushed"
printf 'pushed\n' > "$FIXTURE/persist/git/repo-tag-unpushed/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" commit -q -m "pushed commit"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" remote add origin "$FIXTURE/remotes/repo-tag-unpushed.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" push -q origin main
printf 'pushed\nunpushed via tag only\n' > "$FIXTURE/persist/git/repo-tag-unpushed/pushed.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" commit -q -am "unpushed, kept alive only by a tag"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" tag keep-me-tag
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-tag-unpushed" reset -q --hard origin/main

# --- Mid-task addition: a NESTED git repository (a plain subdirectory
# containing its own .git, not a submodule) inside an at-risk-whole outer
# repo -- found live on the primary guest, 2026-09-27
# (git/shopping/scraper nested inside git/shopping, both without a
# remote): the outer whole-repo walk previously walked straight through
# the nested repo's working tree AND its .git (keep-git mode only prunes
# deny-listed cache names, not other repositories' boundaries), while
# dx_pbs_find_repos ALSO discovers the nested repo independently and emits
# it a second time via its own pass -- producing a DUPLICATE path in the
# listing. The duplicate then made the guest's tar treat the second
# occurrence as a hardlink to the first, which the host's tar refused
# ("hardlink pointing to itself"). Every path must be listed exactly once,
# whichever repo's own pass is responsible for it. ---
git_repo "$FIXTURE/persist/git/repo-outer"
printf 'outer file\n' > "$FIXTURE/persist/git/repo-outer/outer.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer" commit -q -m "outer, no remote"
git_repo "$FIXTURE/persist/git/repo-outer/nested"
printf 'nested file\n' > "$FIXTURE/persist/git/repo-outer/nested/inner.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested" commit -q -m "nested, no remote either"

# --- A SECOND nested case: the nested repo is itself SAFE (pushed,
# clean) -- proves the fix does not just avoid a duplicate, but also
# stops the outer whole-repo walk from over-including a nested safe
# repo's clean, already-pushed content (which it previously did, since
# the outer walk has no way to know the nested repo's OWN git status;
# only the nested repo's own independent pass does). ---
# shellcheck disable=SC2218
git init -q --bare "$FIXTURE/remotes/repo-nested-safe.git"
git_repo "$FIXTURE/persist/git/repo-outer/nested-safe"
printf 'nested safe, clean\n' > "$FIXTURE/persist/git/repo-outer/nested-safe/clean.txt"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested-safe" add -A
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested-safe" commit -q -m "nested, pushed and clean"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested-safe" remote add origin "$FIXTURE/remotes/repo-nested-safe.git"
# shellcheck disable=SC2218
git -C "$FIXTURE/persist/git/repo-outer/nested-safe" push -q origin main

# --- Loose file outside any repository. ---
mkdir -p "$FIXTURE/persist/home/dx"
printf 'history\n' > "$FIXTURE/persist/home/dx/.bash_history"

# --- Deny-listed cache dir OUTSIDE any repository. ---
mkdir -p "$FIXTURE/persist/home/dx/.cache/pip"
printf 'cache\n' > "$FIXTURE/persist/home/dx/.cache/pip/wheel"

# --- Nix-profile generations tree: denied by the built-in path pattern. ---
mkdir -p "$FIXTURE/persist/home/dx/.local/state/dx-ai/generations/7"
ln -s /nix/store/does-not-matter "$FIXTURE/persist/home/dx/.local/state/dx-ai/generations/7/profile"

# --- Branch 18: additional built-in component-deny entries. ---
# pnpm's content-addressable package store.
mkdir -p "$FIXTURE/persist/home/dx/.pnpm-store/v3/files/ab"
printf 'pkgdata\n' > "$FIXTURE/persist/home/dx/.pnpm-store/v3/files/ab/content"
# A trash directory.
mkdir -p "$FIXTURE/persist/home/dx/.Trash-1000"
printf 'deleted\n' > "$FIXTURE/persist/home/dx/.Trash-1000/oldfile.txt"
# Transient scratch (e.g. under ~/.codex), alongside real, kept session
# history in the same persisted directory -- proves the deny is scoped to
# the literal `.tmp` component, not the whole `.codex` tree.
mkdir -p "$FIXTURE/persist/home/dx/.codex/.tmp"
printf 'scratch\n' > "$FIXTURE/persist/home/dx/.codex/.tmp/workfile"
mkdir -p "$FIXTURE/persist/home/dx/.codex/sessions"
printf 'session data\n' > "$FIXTURE/persist/home/dx/.codex/sessions/rollout.json"

# --- Branch 18: additional built-in path-deny entry -- the agy binary
# bundle dx-ai reinstalls, alongside a sibling .gemini path that must stay
# in (its config/credentials). ---
mkdir -p "$FIXTURE/persist/home/dx/.gemini/antigravity-cli/bin"
printf 'binary\n' > "$FIXTURE/persist/home/dx/.gemini/antigravity-cli/bin/agy"
mkdir -p "$FIXTURE/persist/home/dx/.gemini/other-config"
printf 'keep me\n' > "$FIXTURE/persist/home/dx/.gemini/other-config/settings.json"

# --- A dangling symlink outside any repository: mirrored as a symlink. ---
ln -s /no/such/target "$FIXTURE/persist/home/dx/.dangling"

# --- A fifo: skipped and counted, never listed. ---
mkfifo "$FIXTURE/persist/home/dx/.a-fifo" 2>/dev/null || test_skip "mkfifo unavailable on this host; special-file skip case not exercised"

# --- A `.git` FILE (linked worktree / submodule marker), not a directory:
# must not be treated as a repository boundary; falls through to "outside
# any repository -> always at-risk", with a warning to stderr. ---
mkdir -p "$FIXTURE/persist/git/worktree-like"
printf 'gitdir: /elsewhere\n' > "$FIXTURE/persist/git/worktree-like/.git"
printf 'still here\n' > "$FIXTURE/persist/git/worktree-like/marker.txt"

# --- A user-supplied exclude pattern (stands in for DX_BACKUP_EXCLUDE_FILE,
# whose line-reading lives in bin/dx-backup; the selector itself just takes
# extra deny patterns as trailing arguments). ---
mkdir -p "$FIXTURE/persist/scratch"
printf 'drop me\n' > "$FIXTURE/persist/scratch/throwaway.tmp"

listing_file="$FIXTURE/listing.tsv"
stderr_file="$FIXTURE/stderr.log"
dx_pbs_list "$FIXTURE/persist" 'scratch/*.tmp' > "$listing_file" 2> "$stderr_file"

paths_only="$FIXTURE/paths.txt"
cut -f1 "$listing_file" | LC_ALL=C sort > "$paths_only"

assert_listed() {
    local path="$1" message="${2:-$1 is included}"
    if grep -Fxq -- "$path" "$paths_only"; then test_pass "$message"; else test_fail "$message"; fi
}
assert_not_listed() {
    local path="$1" message="${2:-$1 is excluded}"
    if grep -Fxq -- "$path" "$paths_only"; then test_fail "$message"; else test_pass "$message"; fi
}

# Repo-a: safe repo (pushed HEAD, has a remote) -- only its dirty subset.
assert_not_listed "git/repo-a/unchanged.txt" "committed, pushed, unmodified file is excluded"
assert_listed "git/repo-a/modified.txt" "modified tracked file is included"
assert_listed "git/repo-a/staged-new.txt" "staged new file is included"
assert_listed "git/repo-a/untracked.txt" "untracked, not-ignored file is included"
assert_listed "git/repo-a/secret.local" "gitignored file is included by default (never silently dropped)"
assert_listed "git/repo-a/.gitignore" "the .gitignore file itself (staged) is included"
assert_not_listed "git/repo-a/node_modules/pkg/index.js" "deny-listed cache dir inside a repo is excluded even when untracked"
assert_not_listed "git/repo-a/node_modules/pkg/new-dep.js" "deny-listed cache dir inside a repo is excluded (second file)"
assert_not_listed "git/repo-a/.git/HEAD" "a safe repo's .git directory itself is not mirrored"

# Repo-b: unpushed local commit -> at risk as a whole.
assert_listed "git/repo-b/file.txt" "a repo with an unpushed commit is at-risk as a whole (working file)"
assert_listed "git/repo-b/.git/HEAD" "a repo with an unpushed commit mirrors .git too, so the commit itself survives"
assert_listed "git/repo-b/.git/refs/heads/main" "unpushed repo's refs are mirrored"

# Repo-c: no remote at all -> at risk as a whole, even fully committed+clean.
assert_listed "git/repo-c/clean.txt" "a repo with no remote at all is at-risk as a whole (committed file)"
assert_listed "git/repo-c/.git/HEAD" "a repo with no remote at all mirrors .git too"

# Repo-detached (WP6.2 / Astra F2): a local-only commit on DETACHED HEAD is
# at-risk as a whole, same as any other local-only commit.
assert_listed "git/repo-detached/pushed.txt" "a detached-HEAD local-only commit's file is at-risk as a whole"
assert_listed "git/repo-detached/.git/HEAD" "a detached-HEAD local-only commit mirrors .git too (the commit itself survives)"

# Repo-stash (WP6.2): stash-only work (everything else pushed and clean)
# is retained -- at-risk as a whole, via refs/stash reachability.
assert_listed "git/repo-stash/pushed.txt" "a repo whose only unpushed work is a stash is at-risk as a whole"

# Repo-tag-local (WP6.2): a local-only tag on an ALREADY-PUSHED, clean
# commit does not by itself make the repo at-risk.
assert_not_listed "git/repo-tag-local/pushed.txt" "a local-only tag on an already-pushed, clean commit does not drag the whole repo into the listing"
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-tag-local"; then test_fail "a local-only tag on an already-pushed commit is NOT at-risk as a whole"; else test_pass "a local-only tag on an already-pushed commit is NOT at-risk as a whole"; fi

# Repo-tag-unpushed (WP6.2): a local tag on an unpushed commit still
# flags at-risk-whole, even once no branch points there any more.
assert_listed "git/repo-tag-unpushed/.git/refs/tags/keep-me-tag" "the local tag ref itself (and the commit object it protects) is mirrored when at-risk-whole"
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-tag-unpushed"; then test_pass "a local tag on an unpushed commit (even after the branch itself no longer points there) is at-risk as a whole"; else test_fail "a local tag on an unpushed commit (even after the branch itself no longer points there) is at-risk as a whole"; fi

# Outside any repository.
assert_listed "home/dx/.bash_history" "a file outside any repository is always at-risk"
assert_not_listed "home/dx/.cache/pip/wheel" "a deny-listed cache dir outside any repository is excluded"
assert_not_listed "home/dx/.local/state/dx-ai/generations/7/profile" "the Nix-profile generations tree is excluded by the built-in path pattern"
assert_not_listed "scratch/throwaway.tmp" "DX_BACKUP_EXCLUDE_FILE-style user pattern is honoured"

# Branch 18: additional built-in deny entries.
assert_not_listed "home/dx/.pnpm-store/v3/files/ab/content" "pnpm's content-addressable store (.pnpm-store) is excluded"
assert_not_listed "home/dx/.Trash-1000/oldfile.txt" "a trash directory (.Trash-*) is excluded"
assert_not_listed "home/dx/.codex/.tmp/workfile" "a .tmp scratch directory (e.g. under .codex) is excluded"
assert_listed "home/dx/.codex/sessions/rollout.json" "real session history beside a .tmp scratch dir stays in"
assert_not_listed "home/dx/.gemini/antigravity-cli/bin/agy" "the agy binary bundle (.gemini/antigravity-cli) is excluded (dx-ai reinstalls it)"
assert_listed "home/dx/.gemini/other-config/settings.json" "other .gemini content (config/credentials) is not excluded"

# `.git` FILE (linked worktree/submodule marker): not a repo boundary.
assert_listed "git/worktree-like/marker.txt" "content beside a .git FILE (not directory) falls through to always-at-risk"
if grep -Fq "$FIXTURE/persist/git/worktree-like/.git" "$stderr_file" && grep -qi warning "$stderr_file"; then
    test_pass "a .git file (not directory) is warned about, not silently reinterpreted"
else
    test_fail "a .git file (not directory) is warned about, not silently reinterpreted"
fi

# Symlinks are mirrored as symlinks: size equals the target string length.
dangling_line="$(grep -F "$(printf 'home/dx/.dangling\t')" "$listing_file" || true)"
if [ -n "$dangling_line" ]; then
    dangling_size="$(printf '%s\n' "$dangling_line" | cut -f2)"
    expected_len="$(printf '%s' /no/such/target | wc -c | tr -d '[:space:]')"
    if [ "$dangling_size" = "$expected_len" ]; then test_pass "a dangling symlink is mirrored as a symlink (size = target string length)"; else test_fail "a dangling symlink is mirrored as a symlink (size = target string length, got $dangling_size expected $expected_len)"; fi
else
    test_fail "a dangling symlink outside any repository is included in the listing"
fi

# Special files (fifo) are skipped and counted, never listed.
assert_not_listed "home/dx/.a-fifo" "a fifo is never listed"
if grep -Eq 'special file\(s\)' "$stderr_file"; then
    if grep -Eq '^Selector summary: [1-9][0-9]* special file' "$stderr_file"; then
        test_pass "special files (fifo) are counted in the summary"
    else
        test_fail "special files (fifo) are counted in the summary"
    fi
else
    test_fail "selector prints a special-file summary line"
fi

# Every listing line has exactly path/size/mtime/sha256.
malformed="$(awk -F'\t' 'NF != 4 { print; count++ } END { exit count ? 1 : 0 }' "$listing_file")"
if [ -z "$malformed" ]; then test_pass "every listing line has exactly path/size/mtime/sha256"; else test_fail "every listing line has exactly path/size/mtime/sha256: $malformed"; fi

# --- dx_pbs_path_denied: direct unit-level checks. ---
# DX_PBS_EXTRA_DENY is read by dx_pbs_path_denied itself (sourced from the
# selector library, a separate file ShellCheck does not follow here), not
# used directly in this file.
# shellcheck disable=SC2034
DX_PBS_EXTRA_DENY=""
if dx_pbs_path_denied "a/b/node_modules/c"; then test_pass "dx_pbs_path_denied: node_modules denies at any depth"; else test_fail "dx_pbs_path_denied: node_modules denies at any depth"; fi
if dx_pbs_path_denied "result-abc123"; then test_pass "dx_pbs_path_denied: result-* glob matches"; else test_fail "dx_pbs_path_denied: result-* glob matches"; fi
if dx_pbs_path_denied "home/dx/.local/state/dx-ai/generations/9/profile"; then test_pass "dx_pbs_path_denied: Nix-profile generations pattern matches"; else test_fail "dx_pbs_path_denied: Nix-profile generations pattern matches"; fi
if dx_pbs_path_denied "home/dx/.local/state/dx-ai/generations/9/profile/bin/tool"; then test_pass "dx_pbs_path_denied: Nix-profile generations pattern matches beneath the leaf too"; else test_fail "dx_pbs_path_denied: Nix-profile generations pattern matches beneath the leaf too"; fi
if dx_pbs_path_denied "git/repo-a/unchanged.txt"; then test_fail "dx_pbs_path_denied: an ordinary tracked file is not denied"; else test_pass "dx_pbs_path_denied: an ordinary tracked file is not denied"; fi
# shellcheck disable=SC2034
DX_PBS_EXTRA_DENY="scratch/*.tmp"
if dx_pbs_path_denied "scratch/throwaway.tmp"; then test_pass "dx_pbs_path_denied: extra (user) deny pattern matches"; else test_fail "dx_pbs_path_denied: extra (user) deny pattern matches"; fi
# shellcheck disable=SC2034
DX_PBS_EXTRA_DENY=""

# --- Regression (Fable B5 / WP3.3 defect A): a `for pattern in $VAR` word
# list undergoes BOTH word-splitting AND pathname (glob) expansion against
# the CURRENT DIRECTORY. A CWD entry that happens to match a deny pattern's
# glob (e.g. "result-*") silently REPLACES the pattern word itself with the
# matched filename before it is ever compared, breaking the deny check for
# every other path that pattern was meant to match -- reproduced by
# Fable from a directory containing a file literally named "result-bin".
# The selector itself never `cd`s (its CWD is whatever `container
# exec`/`docker exec` supplies), so this is a real, live-reachable
# condition, not a test artefact. ---
cwd_glob_dir="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-cwdglob.XXXXXX")"
: > "$cwd_glob_dir/result-bin"
(
    cd "$cwd_glob_dir" || exit 1
    dx_pbs_path_denied "p/result-abc"
)
cwd_glob_rc=$?
rm -rf "$cwd_glob_dir"
if [ "$cwd_glob_rc" -eq 0 ]; then
    test_pass "dx_pbs_path_denied: a CWD entry matching a deny glob (result-bin) does not stop that same glob from denying an unrelated path (result-abc)"
else
    test_fail "dx_pbs_path_denied: a CWD entry matching a deny glob (result-bin) does not stop that same glob from denying an unrelated path (result-abc)"
fi

# --- Regression (Fable B5 / WP3.3 defect B): dx_pbs_list_driver joins every
# extra deny pattern from its own argv with `DX_PBS_EXTRA_DENY="$*"`,
# flattening N separate patterns into ONE space-joined string BEFORE
# dx_pbs_path_denied ever sees them -- so multiple extra patterns passed
# together stop being independent records. A SINGLE extra pattern survives
# "$*"'s join unchanged (nothing to join), so this only shows up with two or
# more extra patterns passed at once -- exactly DX_BACKUP_EXCLUDE_FILE's
# real shape (one pattern per line, all passed as separate positional
# arguments by bin/dx-backup). Uses a small, isolated fixture (not the
# shared $FIXTURE tree above) so the two extra patterns' effects are easy to
# read in isolation. ---
extra_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-extradeny.XXXXXX")"
mkdir -p "$extra_fixture/my dir" "$extra_fixture/my" "$extra_fixture/second"
printf 'denied by the space-containing pattern\n' > "$extra_fixture/my dir/keepme.txt"
printf 'a bare "my" is a DIFFERENT path than "my dir" -- must survive\n' > "$extra_fixture/my/keepme.txt"
printf 'denied by the second, sibling pattern\n' > "$extra_fixture/second/dropme.txt"
extra_listing="$(dx_pbs_list "$extra_fixture" 'my dir/*' 'second/*' 2>/dev/null)"
extra_paths="$(printf '%s\n' "$extra_listing" | cut -f1)"
if printf '%s\n' "$extra_paths" | grep -Fxq "my dir/keepme.txt"; then
    test_fail "a space-containing extra deny pattern is honoured as its own pattern (my dir/* denies my dir/keepme.txt)"
else
    test_pass "a space-containing extra deny pattern is honoured as its own pattern (my dir/* denies my dir/keepme.txt)"
fi
if printf '%s\n' "$extra_paths" | grep -Fxq "second/dropme.txt"; then
    test_fail "a second extra deny pattern still applies alongside a space-containing sibling pattern (second/* denies second/dropme.txt)"
else
    test_pass "a second extra deny pattern still applies alongside a space-containing sibling pattern (second/* denies second/dropme.txt)"
fi
if printf '%s\n' "$extra_paths" | grep -Fxq "my/keepme.txt"; then
    test_pass "a space-containing pattern's anchor is exact -- the bare prefix before the space (my/) is not swept in too"
else
    test_fail "a space-containing pattern's anchor is exact -- the bare prefix before the space (my/) is not swept in too"
fi
rm -rf "$extra_fixture"

# --- dx_pbs_repo_at_risk_whole: direct unit-level checks. ---
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-a"; then test_fail "repo-a (pushed, clean HEAD) is not at-risk as a whole"; else test_pass "repo-a (pushed, clean HEAD) is not at-risk as a whole"; fi
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-b"; then test_pass "repo-b (unpushed commit) is at-risk as a whole"; else test_fail "repo-b (unpushed commit) is at-risk as a whole"; fi
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-c"; then test_pass "repo-c (no remote) is at-risk as a whole"; else test_fail "repo-c (no remote) is at-risk as a whole"; fi

# --- Nested repository (mid-task addition): every path is listed exactly
# once, never duplicated between the outer's and the nested repo's own
# passes. ---
nested_inner_count="$(grep -c -F "$(printf 'git/repo-outer/nested/inner.txt\t')" "$listing_file")"
if [ "$nested_inner_count" -eq 1 ]; then test_pass "a nested repository's file is listed exactly once (not duplicated by the outer whole-repo walk)"; else test_fail "a nested repository's file is listed exactly once (got $nested_inner_count occurrences)"; fi
nested_git_count="$(grep -c -F "$(printf 'git/repo-outer/nested/.git/HEAD\t')" "$listing_file")"
if [ "$nested_git_count" -eq 1 ]; then test_pass "a nested repository's own .git is captured exactly once (its own unpushed history survives)"; else test_fail "a nested repository's own .git is captured exactly once (got $nested_git_count occurrences)"; fi
outer_own_count="$(grep -c -F "$(printf 'git/repo-outer/outer.txt\t')" "$listing_file")"
if [ "$outer_own_count" -eq 1 ]; then test_pass "the outer repo's own file (outside the nested repo) is still listed exactly once"; else test_fail "the outer repo's own file is listed exactly once (got $outer_own_count occurrences)"; fi
assert_not_listed "git/repo-outer/nested-safe/clean.txt" "a nested repo's own clean, pushed file is excluded (handled by its own pass, not swept in by the outer's blind whole-repo walk)"

# --- --hash-paths mode (dx-restore's conflict-check probe). ---
hash_out="$FIXTURE/hash-out.tsv"
dx_pbs_hash_paths "$FIXTURE/persist" home/dx/.bash_history home/dx/.dangling home/dx/does-not-exist > "$hash_out"
if grep -Fxq "$(printf 'home/dx/does-not-exist\tmissing')" "$hash_out"; then test_pass "--hash-paths reports a missing target"; else test_fail "--hash-paths reports a missing target"; fi
if grep -Fq "$(printf 'home/dx/.bash_history\tpresent\t')" "$hash_out"; then test_pass "--hash-paths reports a present file with its hash"; else test_fail "--hash-paths reports a present file with its hash"; fi
if grep -Fq "$(printf 'home/dx/.dangling\tpresent\t')" "$hash_out"; then test_pass "--hash-paths reports a present dangling symlink"; else test_fail "--hash-paths reports a present dangling symlink"; fi

# --- dx_pbs_main dispatch (the executable entry point, BASH_SOURCE-guarded
# exactly like scripts/dx-ai.sh's dx_ai_main). ---
main_out="$(bash "$SELECTOR" --hash-paths "$FIXTURE/persist" home/dx/.bash_history)"
if printf '%s\n' "$main_out" | stdin_matches -F 'home/dx/.bash_history	present	'; then test_pass "dx-persist-backup-select.sh --hash-paths runs standalone"; else test_fail "dx-persist-backup-select.sh --hash-paths runs standalone"; fi
if bash "$SELECTOR" >/dev/null 2>&1; then test_fail "dx-persist-backup-select.sh with no arguments is a usage error"; else test_pass "dx-persist-backup-select.sh with no arguments is a usage error"; fi
standalone_listing="$(bash "$SELECTOR" "$FIXTURE/persist" 2>/dev/null)"
if printf '%s\n' "$standalone_listing" | stdin_matches -F "$(printf 'home/dx/.bash_history\t')"; then test_pass "dx-persist-backup-select.sh runs standalone as the default listing mode"; else test_fail "dx-persist-backup-select.sh runs standalone as the default listing mode"; fi

# --- dx_pbs_hash_entry: the "neither symlink nor regular file" refusal
# (a missing path, and a directory -- hashing a directory makes no sense).
# dx_pbs_hash_paths pre-checks existence itself and never reaches this
# fallback for a missing path, so it needs a direct call to exercise it. ---
if dx_pbs_hash_entry "$FIXTURE/persist/home/dx/does-not-exist" >/dev/null 2>&1; then test_fail "dx_pbs_hash_entry refuses a missing path"; else test_pass "dx_pbs_hash_entry refuses a missing path"; fi
if dx_pbs_hash_entry "$FIXTURE/persist/git" >/dev/null 2>&1; then test_fail "dx_pbs_hash_entry refuses a directory"; else test_pass "dx_pbs_hash_entry refuses a directory"; fi

# --- dx_pbs_sha256_stdin: the shasum fallback, exercised the same way
# test_sourceable_coverage.sh exercises dx_bootstrap_content_digest's own
# sha256sum/shasum tool pick -- hide sha256sum from `command -v` so the
# fallback branch runs for real. The probe itself must run in a subshell (a
# shadowed `command` builtin cannot be undone in the current shell), but the
# test_pass/test_fail call stays OUTSIDE it: test_helpers.sh's pass/fail
# counters are plain shell variables, so incrementing them inside a subshell
# would be invisible to print_summary/exit_with_code in the parent shell. ---
fallback_result="$(
    command() { if [ "${1:-}" = -v ] && [ "${2:-}" = sha256sum ]; then return 1; fi; builtin command "$@"; }
    shasum() { printf '%s\n' 'fallbackhash  -'; }
    printf 'anything' | dx_pbs_sha256_stdin
)"
[ "$fallback_result" = fallbackhash ] && test_pass "dx_pbs_sha256_stdin falls back to shasum when sha256sum is absent" || test_fail "dx_pbs_sha256_stdin falls back to shasum when sha256sum is absent (got '$fallback_result')"

# --- WP6.1 (Astra F1): scan completeness is a contract. A permission-
# denied subtree used to be silently skipped (2>/dev/null on every find,
# no exit-status check anywhere) -- reproduced live: a transient chmod 000
# on a subtree made the listing exit 0 with that subtree simply missing,
# and the host's diff then scheduled the vanished paths for removal from
# the mirror. Fail closed instead: a traversal error must abort the WHOLE
# run (nonzero exit) and name the offending path on stderr, never silently
# narrow the selection. A first, fully-readable listing succeeds; only the
# SECOND listing (after chmod 000) is expected to fail -- run as an
# unprivileged user: root ignores the permission bit entirely and the
# repro would not reproduce. This whole suite normally already runs
# unprivileged (no sudo), which is why the plain `dx_pbs_list` call below
# is enough on a workstation -- but tests/run-coverage-linux.sh's isolated
# kcov image runs the WHOLE suite as root (Astra F1's regression-test
# note: "Run permission tests as an unprivileged user so root does not
# mask the failure"). There, drop to uid/gid 65534 (nobody) with setpriv
# (util-linux; present in the Ubuntu coverage image) for just this second
# listing, via the selector's own standalone entrypoint (its
# `[ "${BASH_SOURCE[0]}" = "$0" ]` trailer calls dx_pbs_main "$@", which
# for a bare ROOT argument is exactly dx_pbs_list "$@" -- see this file's
# own end) rather than the sourced function directly, since a plain
# function call cannot itself change uid. Root without setpriv cannot
# reproduce this at all (mode bits never deny root), so both assertions
# are skipped there rather than silently passing on a non-repro. ---
denied_root="$FIXTURE/wp61-denied-root"
mkdir -p "$denied_root/private/work"
printf 'do not lose me\n' > "$denied_root/private/work/secret.txt"
first_denied_stderr="$FIXTURE/wp61-denied-stderr-1.log"
if dx_pbs_list "$denied_root" > /dev/null 2> "$first_denied_stderr"; then
    test_pass "WP6.1: a fully readable tree lists successfully before anything is made unreadable"
else
    test_fail "WP6.1: a fully readable tree lists successfully before anything is made unreadable (stderr: $(cat "$first_denied_stderr"))"
fi
second_denied_stderr="$FIXTURE/wp61-denied-stderr-2.log"
if [ "$(id -u)" -eq 0 ]; then
    if command -v setpriv > /dev/null 2>&1; then
        # Everything ABOVE the denied subtree must stay traversable for
        # uid 65534 to even reach it: mktemp -d made $FIXTURE 0700, and a
        # root-owned mkdir -p may not have left $denied_root world-
        # traversable either. The denied subtree itself is the thing
        # under test and stays 0000.
        chmod 0755 "$FIXTURE" "$denied_root"
        chmod 0000 "$denied_root/private"
        if setpriv --reuid=65534 --regid=65534 --clear-groups env HOME=/tmp bash "$SELECTOR" "$denied_root" > /dev/null 2> "$second_denied_stderr"; then
            test_fail "WP6.1: a permission-denied subtree makes the second listing exit non-zero (it exited 0)"
        else
            test_pass "WP6.1: a permission-denied subtree makes the second listing exit non-zero"
        fi
        chmod 0755 "$denied_root/private"
        if grep -Fq "$denied_root/private" "$second_denied_stderr" && grep -q '^Error:' "$second_denied_stderr"; then
            test_pass "WP6.1: the permission-denied path is named in an Error: line on stderr"
        else
            test_fail "WP6.1: the permission-denied path is named in an Error: line on stderr (stderr: $(cat "$second_denied_stderr"))"
        fi
    else
        test_skip "WP6.1: a permission-denied subtree makes the second listing exit non-zero (running as root without setpriv: mode bits do not deny root; Astra F1)"
        test_skip "WP6.1: the permission-denied path is named in an Error: line on stderr (running as root without setpriv: mode bits do not deny root; Astra F1)"
    fi
else
    chmod 0000 "$denied_root/private"
    if dx_pbs_list "$denied_root" > /dev/null 2> "$second_denied_stderr"; then
        test_fail "WP6.1: a permission-denied subtree makes the second listing exit non-zero (it exited 0)"
    else
        test_pass "WP6.1: a permission-denied subtree makes the second listing exit non-zero"
    fi
    chmod 0755 "$denied_root/private"
    if grep -Fq "$denied_root/private" "$second_denied_stderr" && grep -q '^Error:' "$second_denied_stderr"; then
        test_pass "WP6.1: the permission-denied path is named in an Error: line on stderr"
    else
        test_fail "WP6.1: the permission-denied path is named in an Error: line on stderr (stderr: $(cat "$second_denied_stderr"))"
    fi
fi

# --- Equivalence property (Fable B5 / Astra F6 / Muse B3, WP3.3 defect C):
# the SAME component deny-list was hand-expanded as literal `find -name`
# clauses at four sites (dx_pbs_walk_repo_files's two branches,
# dx_pbs_list_outside_repos's two branches) as well as declared once in
# DX_PBS_BUILTIN_COMPONENT_DENY -- five independent, hand-synced copies. A
# prior version of this guard only diffed the SOURCE TEXT of the four
# `find` blocks against the variable (a config-parsing check); this
# supersedes it with a BEHAVIOURAL one (constitution: "tests should
# validate behaviour, not simply parsing configuration files"): build a
# fixture containing EVERY built-in component-deny name as its own
# directory (each with one file inside), plus one always-allowed
# directory, then assert dx_pbs_walk_repo_files's and
# dx_pbs_list_outside_repos's own traversal output is EXACTLY the set of
# candidate files dx_pbs_path_denied accepts (denies none of the allowed
# file, accepts none of the denied ones) -- true agreement between the
# matcher and BOTH traversal entry points, not just that their source text
# happens to match today. Scoped to component names only (not
# DX_PBS_BUILTIN_PATH_DENY): PATH_DENY entries are anchored full-path globs,
# never represented as `find -name` prune clauses at all (they are filtered
# downstream, per candidate, by dx_pbs_path_denied itself -- see
# dx_pbs_list_outside_repos and dx_pbs_emit_found_list), so they are
# outside what these four `find` sites are responsible for pruning. ---
eq_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-equiv.XXXXXX")"
mkdir -p "$eq_fixture/allowed"
printf 'kept\n' > "$eq_fixture/allowed/leaf.txt"
for eq_name in node_modules target .direnv result result-anything __pycache__ \
    .cache dist build .venv .tox .pytest_cache .mypy_cache .pnpm-store \
    .Trash-1000 .tmp; do
    mkdir -p "$eq_fixture/$eq_name"
    printf 'denied\n' > "$eq_fixture/$eq_name/leaf.txt"
done
eq_empty_repos="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-equiv-repos.XXXXXX")"
: > "$eq_empty_repos"

eq_walk_paths="$(dx_pbs_walk_repo_files "$eq_fixture" 2>/dev/null | tr '\0' '\n' | grep -v '^$' | LC_ALL=C sort)"
eq_outside_paths="$(dx_pbs_list_outside_repos "$eq_fixture" "$eq_empty_repos" 2>/dev/null | cut -f1 | LC_ALL=C sort)"
eq_accepted="$(
    for eq_name in allowed node_modules target .direnv result result-anything \
        __pycache__ .cache dist build .venv .tox .pytest_cache .mypy_cache \
        .pnpm-store .Trash-1000 .tmp; do
        eq_candidate="$eq_name/leaf.txt"
        dx_pbs_path_denied "$eq_candidate" || printf '%s\n' "$eq_candidate"
    done | LC_ALL=C sort
)"

if [ "$eq_walk_paths" = "allowed/leaf.txt" ]; then
    test_pass "dx_pbs_walk_repo_files's own find-pruning excludes every built-in component-deny name, keeping only the allowed file"
else
    test_fail "dx_pbs_walk_repo_files's own find-pruning excludes every built-in component-deny name, keeping only the allowed file (got: [$eq_walk_paths])"
fi
if [ "$eq_outside_paths" = "allowed/leaf.txt" ]; then
    test_pass "dx_pbs_list_outside_repos excludes every built-in component-deny name, keeping only the allowed file"
else
    test_fail "dx_pbs_list_outside_repos excludes every built-in component-deny name, keeping only the allowed file (got: [$eq_outside_paths])"
fi
if [ "$eq_walk_paths" = "$eq_accepted" ]; then
    test_pass "dx_pbs_walk_repo_files's traversal output is exactly the set dx_pbs_path_denied accepts"
else
    test_fail "dx_pbs_walk_repo_files's traversal output is exactly the set dx_pbs_path_denied accepts (walk: [$eq_walk_paths], matcher-accepted: [$eq_accepted])"
fi
if [ "$eq_outside_paths" = "$eq_accepted" ]; then
    test_pass "dx_pbs_list_outside_repos's traversal output is exactly the set dx_pbs_path_denied accepts"
else
    test_fail "dx_pbs_list_outside_repos's traversal output is exactly the set dx_pbs_path_denied accepts (outside: [$eq_outside_paths], matcher-accepted: [$eq_accepted])"
fi
rm -rf "$eq_fixture"
rm -f "$eq_empty_repos"

# --- Branch 17: --with-reason mode. Every line gets a 5th <TAB>reason
# column: modified-untracked, whole-repo, outside-repo, or ignored-kept.
# Reuses the exact fixtures built above -- no new tree needed, since every
# reason already has a natural example in repo-a/b/c and the outside-repo
# files. `bin/dx-backup --dry-run --summary` aggregates this listing; it
# does not re-derive any selection rule of its own. ---
reason_listing="$FIXTURE/listing-reason.tsv"
dx_pbs_list_with_reason "$FIXTURE/persist" 'scratch/*.tmp' > "$reason_listing" 2>/dev/null

assert_reason() {
    local path="$1" expected="$2" message="${3:-$1 is tagged $2}"
    local got
    got="$(awk -F'\t' -v p="$path" '$1 == p { print $5; exit }' "$reason_listing")"
    if [ "$got" = "$expected" ]; then test_pass "$message"; else test_fail "$message (got '$got')"; fi
}

assert_reason "git/repo-a/modified.txt" "modified-untracked" "a modified tracked file is reasoned modified-untracked"
assert_reason "git/repo-a/staged-new.txt" "modified-untracked" "a staged new file is reasoned modified-untracked"
assert_reason "git/repo-a/untracked.txt" "modified-untracked" "an untracked, not-ignored file is reasoned modified-untracked"
assert_reason "git/repo-a/.gitignore" "modified-untracked" "the tracked-and-staged .gitignore itself is reasoned modified-untracked"
assert_reason "git/repo-a/secret.local" "ignored-kept" "a gitignored-but-kept file is reasoned ignored-kept"
assert_reason "git/repo-b/file.txt" "whole-repo" "a file in an at-risk-whole repo (unpushed commit) is reasoned whole-repo"
assert_reason "git/repo-b/.git/HEAD" "whole-repo" "an at-risk-whole repo's .git contents are reasoned whole-repo too"
assert_reason "git/repo-c/clean.txt" "whole-repo" "a file in an at-risk-whole repo (no remote) is reasoned whole-repo"
assert_reason "home/dx/.bash_history" "outside-repo" "a file outside any repository is reasoned outside-repo"
assert_reason "git/worktree-like/marker.txt" "outside-repo" "content beside a .git FILE (not a repo boundary) is reasoned outside-repo"

# Every line has exactly 5 fields in --with-reason mode (the same "no drift"
# check the plain listing gets above, extended by one column).
malformed_reason="$(awk -F'\t' 'NF != 5 { print; count++ } END { exit count ? 1 : 0 }' "$reason_listing")"
if [ -z "$malformed_reason" ]; then test_pass "every --with-reason listing line has exactly path/size/mtime/sha256/reason"; else test_fail "every --with-reason listing line has exactly path/size/mtime/sha256/reason: $malformed_reason"; fi

# The plain (no-reason) listing is byte-for-byte unaffected by the
# --with-reason code path existing at all.
reason_stripped="$(cut -f1-4 "$reason_listing" | LC_ALL=C sort)"
plain_sorted="$(LC_ALL=C sort "$listing_file")"
if [ "$reason_stripped" = "$plain_sorted" ]; then test_pass "the plain listing and the reason listing agree on path/size/mtime/sha256"; else test_fail "the plain listing and the reason listing agree on path/size/mtime/sha256"; fi

# --- dx_pbs_main dispatch: --with-reason and --hash-paths-file standalone. ---
standalone_reason="$(bash "$SELECTOR" --with-reason "$FIXTURE/persist" 2>/dev/null)"
if printf '%s\n' "$standalone_reason" | stdin_matches -F "$(printf 'home/dx/.bash_history\t')" && printf '%s\n' "$standalone_reason" | stdin_matches -F 'outside-repo'; then
    test_pass "dx-persist-backup-select.sh --with-reason runs standalone"
else
    test_fail "dx-persist-backup-select.sh --with-reason runs standalone"
fi

hashpaths_list="$FIXTURE/hashpaths-list.txt"
printf '%s\n' home/dx/.bash_history home/dx/.dangling home/dx/does-not-exist > "$hashpaths_list"
hash_file_out="$FIXTURE/hash-file-out.tsv"
dx_pbs_hash_paths_file "$FIXTURE/persist" "$hashpaths_list" > "$hash_file_out"
if [ "$(cat "$hash_file_out")" = "$(cat "$hash_out")" ]; then
    test_pass "--hash-paths-file agrees with --hash-paths for the same paths"
else
    test_fail "--hash-paths-file agrees with --hash-paths for the same paths (file: $(cat "$hash_file_out"), argv: $(cat "$hash_out"))"
fi
standalone_hash_file="$(bash "$SELECTOR" --hash-paths-file "$FIXTURE/persist" "$hashpaths_list")"
if printf '%s\n' "$standalone_hash_file" | stdin_matches -F 'home/dx/.bash_history	present	'; then test_pass "dx-persist-backup-select.sh --hash-paths-file runs standalone"; else test_fail "dx-persist-backup-select.sh --hash-paths-file runs standalone"; fi

# --- WP6.1 (Astra F1): a `find` that fails outright (not just permission-
# denied) must also abort the whole run, even when it printed SOME output
# first -- the exact "partial output, then nonzero exit" shape Astra's own
# fixture used (proves the EXIT STATUS is what is checked, not merely
# "stderr looked quiet"). Scoped to a small, isolated fixture with no git
# repos, so only dx_pbs_list_outside_repos's own find call matters here.
# `find` is shadowed as a shell FUNCTION, undone with a plain `unset -f`. ---
find_fail_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-findfail.XXXXXX")"
mkdir -p "$find_fail_root/home/dx"
printf 'irrelevant\n' > "$find_fail_root/home/dx/file.txt"
find() { printf 'partial/output\0'; return 1; }
find_fail_stderr="$FIXTURE/wp61-findfail-stderr.log"
if dx_pbs_list "$find_fail_root" > /dev/null 2> "$find_fail_stderr"; then
    test_fail "WP6.1: a failing find (after printing partial output) makes the listing exit non-zero"
else
    test_pass "WP6.1: a failing find (after printing partial output) makes the listing exit non-zero"
fi
unset -f find
if grep -q '^Error:' "$find_fail_stderr"; then
    test_pass "WP6.1: a failing find's Error is reported on stderr"
else
    test_fail "WP6.1: a failing find's Error is reported on stderr (stderr: $(cat "$find_fail_stderr"))"
fi
rm -rf "$find_fail_root"

# --- WP6.1: a file that "disappears" between being listed by find and
# being stat/hashed (a real race on a live guest; here, a shadowed `stat`
# stands in for it) must also abort the run and name the affected path,
# never silently `continue` past it. `stat` is shadowed to fail ONLY for
# the one target path (both the -c and -f probes dx_pbs_stat_size/
# dx_pbs_stat_mtime try), leaving every other path's real stat call
# untouched -- proving the failure is scoped to that ONE entry. ---
stat_fail_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-statfail.XXXXXX")"
mkdir -p "$stat_fail_root/home/dx"
printf 'vanishing\n' > "$stat_fail_root/home/dx/vanishes.txt"
printf 'stays\n' > "$stat_fail_root/home/dx/stays.txt"
stat() {
    case "$*" in
        *vanishes.txt*) return 1 ;;
        *) command stat "$@" ;;
    esac
}
stat_fail_stderr="$FIXTURE/wp61-statfail-stderr.log"
if dx_pbs_list "$stat_fail_root" > /dev/null 2> "$stat_fail_stderr"; then
    test_fail "WP6.1: a path whose stat/hash fails makes the listing exit non-zero"
else
    test_pass "WP6.1: a path whose stat/hash fails makes the listing exit non-zero"
fi
unset -f stat
if grep -Fq "vanishes.txt" "$stat_fail_stderr" && grep -q '^Error:' "$stat_fail_stderr"; then
    test_pass "WP6.1: the path whose stat/hash failed is named in an Error: line"
else
    test_fail "WP6.1: the path whose stat/hash failed is named in an Error: line (stderr: $(cat "$stat_fail_stderr"))"
fi
rm -rf "$stat_fail_root"

# --- WP6.1: a failed Git inspection (e.g. a corrupted repo; here, a
# shadowed `git` standing in for any git-level failure) for ONE repository
# must also abort the run and name that repository, never be silently
# reclassified "safe" -- the one misclassification that can lose data.
# `git` is shadowed to fail only for the one target repo (matched by its
# path appearing anywhere in the invocation's arguments -- every call in
# this file passes `-C "$repo"`), leaving every other repository's real
# git calls untouched. ---
git_fail_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-gitfail.XXXXXX")"
mkdir -p "$git_fail_root/git"
# shellcheck disable=SC2218
git init -q -b main "$git_fail_root/git/broken-repo"
# shellcheck disable=SC2218
git -C "$git_fail_root/git/broken-repo" config user.email test@example.com
# shellcheck disable=SC2218
git -C "$git_fail_root/git/broken-repo" config user.name "DXE Test"
printf 'content\n' > "$git_fail_root/git/broken-repo/file.txt"
# shellcheck disable=SC2218
git -C "$git_fail_root/git/broken-repo" add -A
# shellcheck disable=SC2218
git -C "$git_fail_root/git/broken-repo" commit -q -m initial
git_fail_target="$git_fail_root/git/broken-repo"
git() {
    case "$*" in
        *"$git_fail_target"*) return 128 ;;
        *) command git "$@" ;;
    esac
}
git_fail_stderr="$FIXTURE/wp61-gitfail-stderr.log"
if dx_pbs_list "$git_fail_root" > /dev/null 2> "$git_fail_stderr"; then
    test_fail "WP6.1: a repository whose git inspection fails makes the listing exit non-zero (not silently 'safe')"
else
    test_pass "WP6.1: a repository whose git inspection fails makes the listing exit non-zero (not silently 'safe')"
fi
unset -f git
if grep -Fq "$git_fail_target" "$git_fail_stderr" && grep -q '^Error:' "$git_fail_stderr"; then
    test_pass "WP6.1: the repository whose git inspection failed is named in an Error: line"
else
    test_fail "WP6.1: the repository whose git inspection failed is named in an Error: line (stderr: $(cat "$git_fail_stderr"))"
fi
rm -rf "$git_fail_root"

# --- WP6.2: a repository whose reachability cannot be established (a
# failed git query, not merely "no remote") is retained CONSERVATIVELY --
# treated as at-risk-whole, exactly like a repo with real local-only
# commits -- AND the run is reported as a failure (WP6.1's completeness
# contract), never silently "safe". Verified at both levels: the
# risk-check's own return code (2: distinct from both "0 = at risk" and
# "1 = safe" -- see the retention-policy comment above
# dx_pbs_repo_at_risk_whole), and dx_pbs_emit_repo's actual output (the
# repo's tracked, already-pushed file is present in the listing precisely
# BECAUSE whole-repo mode ran, not the safe/clean-set-diff path, which
# would have excluded it). ---
git_unreach_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-gitunreach.XXXXXX")"
mkdir -p "$git_unreach_root/git"
# shellcheck disable=SC2218
git init -q --bare "$git_unreach_root/remote.git"
# shellcheck disable=SC2218
git init -q -b main "$git_unreach_root/git/repo"
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" config user.email test@example.com
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" config user.name "DXE Test"
printf 'pushed and clean\n' > "$git_unreach_root/git/repo/pushed.txt"
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" add -A
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" commit -q -m initial
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" remote add origin "$git_unreach_root/remote.git"
# shellcheck disable=SC2218
git -C "$git_unreach_root/git/repo" push -q origin main
git_unreach_target="$git_unreach_root/git/repo"
git() {
    case "$*" in
        *"$git_unreach_target"*) return 128 ;;
        *) command git "$@" ;;
    esac
}
dx_pbs_repo_at_risk_whole "$git_unreach_target"
git_unreach_rc=$?
if [ "$git_unreach_rc" -eq 2 ]; then
    test_pass "WP6.2: a repository whose git reachability query fails is signalled distinctly (conservative retention + reported failure), not 'safe'"
else
    test_fail "WP6.2: a repository whose git reachability query fails is signalled distinctly (conservative retention + reported failure), not 'safe' (rc=$git_unreach_rc)"
fi

git_unreach_repos_file="$(mktemp "${TMPDIR:-/tmp}/dxe-pbs-gitunreach-repos.XXXXXX")"
printf '%s\n' "$git_unreach_target" > "$git_unreach_repos_file"
git_unreach_out="$FIXTURE/wp62-gitunreach-out.tsv"
set +e
dx_pbs_emit_repo "$git_unreach_target" "repo" "" "$git_unreach_repos_file" > "$git_unreach_out" 2>/dev/null
emit_repo_rc=$?
set -e
unset -f git
if [ "$emit_repo_rc" -ne 0 ]; then
    test_pass "WP6.2: dx_pbs_emit_repo reports failure for a repository whose reachability could not be established"
else
    test_fail "WP6.2: dx_pbs_emit_repo reports failure for a repository whose reachability could not be established"
fi
if grep -Fq "$(printf 'repo/pushed.txt\t')" "$git_unreach_out"; then
    test_pass "WP6.2: despite the failure, the repository's content is retained conservatively (whole-repo emission still ran)"
else
    test_fail "WP6.2: despite the failure, the repository's content is retained conservatively (whole-repo emission still ran)"
fi
rm -f "$git_unreach_repos_file" "$git_unreach_out"
rm -rf "$git_unreach_root"

# --- WP6.1 coverage: dx_pbs_repo_clean_set's own two `git` failure branches
# (ls-tree, then diff), exercised directly rather than only through the
# whole-listing driver above (which never distinguishes WHICH git subcommand
# failed). Reuses the shadow-`git` idiom above (a function matching by
# substring against "$*", forwarding everything else to `command git "$@"`),
# narrowed to the exact subcommand so the sibling call still runs for real --
# proving each branch is reached on its own. Also checks that the failure
# path leaves no temp file behind (the mktemp names the cleanup line frees:
# dxe-pbs-all./dxe-pbs-diff./dxe-pbs-cleanerr., all under $TMPDIR), a
# before/after count rather than racing the cleanup itself. ---
dxe_pbs_clean_tmp_count() {
    find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name 'dxe-pbs-all.*' -o -name 'dxe-pbs-diff.*' -o -name 'dxe-pbs-cleanerr.*' \) 2>/dev/null | wc -l | tr -d '[:space:]'
}

clean_lstree_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-cleanlstree.XXXXXX")"
mkdir -p "$clean_lstree_root/git"
# shellcheck disable=SC2218
git init -q -b main "$clean_lstree_root/git/repo"
# shellcheck disable=SC2218
git -C "$clean_lstree_root/git/repo" config user.email test@example.com
# shellcheck disable=SC2218
git -C "$clean_lstree_root/git/repo" config user.name "DXE Test"
printf 'content\n' > "$clean_lstree_root/git/repo/file.txt"
# shellcheck disable=SC2218
git -C "$clean_lstree_root/git/repo" add -A
# shellcheck disable=SC2218
git -C "$clean_lstree_root/git/repo" commit -q -m initial
clean_lstree_target="$clean_lstree_root/git/repo"
git() {
    case "$*" in
        *"$clean_lstree_target ls-tree"*) return 1 ;;
        *) command git "$@" ;;
    esac
}
clean_lstree_out="$FIXTURE/clean-lstree-out.tsv"
clean_lstree_stderr="$FIXTURE/clean-lstree-stderr.log"
clean_lstree_tmp_before="$(dxe_pbs_clean_tmp_count)"
set +e
dx_pbs_repo_clean_set "$clean_lstree_target" "$clean_lstree_out" 2> "$clean_lstree_stderr"
clean_lstree_rc=$?
set -e
clean_lstree_tmp_after="$(dxe_pbs_clean_tmp_count)"
unset -f git
if [ "$clean_lstree_rc" -ne 0 ]; then
    test_pass "dx_pbs_repo_clean_set reports failure when git ls-tree fails (dx-persist-backup-select.sh:282-284)"
else
    test_fail "dx_pbs_repo_clean_set reports failure when git ls-tree fails (dx-persist-backup-select.sh:282-284)"
fi
if grep -Fq "Error: git ls-tree failed:" "$clean_lstree_stderr" && grep -Fq "$clean_lstree_target" "$clean_lstree_stderr"; then
    test_pass "the git-ls-tree failure names the repository in an Error: line"
else
    test_fail "the git-ls-tree failure names the repository in an Error: line (stderr: $(cat "$clean_lstree_stderr"))"
fi
if [ "$clean_lstree_tmp_before" = "$clean_lstree_tmp_after" ]; then
    test_pass "dx_pbs_repo_clean_set's git-ls-tree failure leaves no temp file behind"
else
    test_fail "dx_pbs_repo_clean_set's git-ls-tree failure leaves no temp file behind (before=$clean_lstree_tmp_before after=$clean_lstree_tmp_after)"
fi
rm -rf "$clean_lstree_root"

clean_diff_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-cleandiff.XXXXXX")"
mkdir -p "$clean_diff_root/git"
# shellcheck disable=SC2218
git init -q -b main "$clean_diff_root/git/repo"
# shellcheck disable=SC2218
git -C "$clean_diff_root/git/repo" config user.email test@example.com
# shellcheck disable=SC2218
git -C "$clean_diff_root/git/repo" config user.name "DXE Test"
printf 'content\n' > "$clean_diff_root/git/repo/file.txt"
# shellcheck disable=SC2218
git -C "$clean_diff_root/git/repo" add -A
# shellcheck disable=SC2218
git -C "$clean_diff_root/git/repo" commit -q -m initial
clean_diff_target="$clean_diff_root/git/repo"
git() {
    case "$*" in
        *"$clean_diff_target diff"*) return 1 ;;
        *) command git "$@" ;;
    esac
}
clean_diff_out="$FIXTURE/clean-diff-out.tsv"
clean_diff_stderr="$FIXTURE/clean-diff-stderr.log"
clean_diff_tmp_before="$(dxe_pbs_clean_tmp_count)"
set +e
dx_pbs_repo_clean_set "$clean_diff_target" "$clean_diff_out" 2> "$clean_diff_stderr"
clean_diff_rc=$?
set -e
clean_diff_tmp_after="$(dxe_pbs_clean_tmp_count)"
unset -f git
if [ "$clean_diff_rc" -ne 0 ]; then
    test_pass "dx_pbs_repo_clean_set reports failure when git diff fails (dx-persist-backup-select.sh:289-291)"
else
    test_fail "dx_pbs_repo_clean_set reports failure when git diff fails (dx-persist-backup-select.sh:289-291)"
fi
if grep -Fq "Error: git diff failed:" "$clean_diff_stderr" && grep -Fq "$clean_diff_target" "$clean_diff_stderr"; then
    test_pass "the git-diff failure names the repository in an Error: line"
else
    test_fail "the git-diff failure names the repository in an Error: line (stderr: $(cat "$clean_diff_stderr"))"
fi
if [ "$clean_diff_tmp_before" = "$clean_diff_tmp_after" ]; then
    test_pass "dx_pbs_repo_clean_set's git-diff failure leaves no temp file behind"
else
    test_fail "dx_pbs_repo_clean_set's git-diff failure leaves no temp file behind (before=$clean_diff_tmp_before after=$clean_diff_tmp_after)"
fi
rm -rf "$clean_diff_root"

# --- WP6.1 coverage: dx_pbs_walk_repo_files's OWN "directory traversal
# failed" branch (find fails inside the walker's own per-repo subshell) --
# distinct from dx_pbs_list_outside_repos's separate find-failure branch
# already covered above ("a failing find (after printing partial output)
# makes the listing exit non-zero"), which is a different call site. Reached
# by calling the walker directly on a small, standalone repo directory (not
# via the full listing driver), so only THIS call site's `find` is under
# test. Reuses the same unconditional-failure `find` shadow used above. ---
walk_fail_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-walkfail.XXXXXX")"
mkdir -p "$walk_fail_root/repo"
printf 'content\n' > "$walk_fail_root/repo/file.txt"
walk_fail_target="$walk_fail_root/repo"
find() { printf 'partial/output\0'; return 1; }
walk_fail_stderr="$FIXTURE/wp61-walkfail-stderr.log"
set +e
dx_pbs_walk_repo_files "$walk_fail_target" > /dev/null 2> "$walk_fail_stderr"
walk_fail_rc=$?
set -e
unset -f find
if [ "$walk_fail_rc" -ne 0 ]; then
    test_pass "dx_pbs_walk_repo_files reports failure when its own directory traversal fails (dx-persist-backup-select.sh:411-413)"
else
    test_fail "dx_pbs_walk_repo_files reports failure when its own directory traversal fails (dx-persist-backup-select.sh:411-413)"
fi
if grep -Fq "directory traversal failed" "$walk_fail_stderr" && grep -Fq "$walk_fail_target" "$walk_fail_stderr" && grep -q '^Error:' "$walk_fail_stderr"; then
    test_pass "the walker's directory-traversal failure names the repository directory in an Error: line"
else
    test_fail "the walker's directory-traversal failure names the repository directory in an Error: line (stderr: $(cat "$walk_fail_stderr"))"
fi
rm -rf "$walk_fail_root"

# --- WP6.1 coverage: dx_pbs_emit_repo_safe's own "git ls-files failed"
# branch, reached only in --with-reason mode (the plain listing never calls
# git ls-files at all -- see the function's own comment). Exercised by
# calling dx_pbs_emit_repo_safe directly with reason_mode set, on a small,
# standalone, pushed-and-clean repo (its at-risk-whole status is irrelevant
# here: dx_pbs_emit_repo_safe itself never consults it, only its own caller
# dx_pbs_emit_repo does). Also checks the failure path leaves no temp file
# behind, same before/after idiom as the clean_set cases above. ---
dxe_pbs_emitsafe_tmp_count() {
    find "${TMPDIR:-/tmp}" -maxdepth 1 \( -name 'dxe-pbs-clean.*' -o -name 'dxe-pbs-found.*' -o -name 'dxe-pbs-delta.*' -o -name 'dxe-pbs-ignored.*' -o -name 'dxe-pbs-ignoredrr.*' \) 2>/dev/null | wc -l | tr -d '[:space:]'
}
emitsafe_root="$(mktemp -d "${TMPDIR:-/tmp}/dxe-pbs-emitsafe.XXXXXX")"
mkdir -p "$emitsafe_root/git"
# shellcheck disable=SC2218
git init -q -b main "$emitsafe_root/git/repo"
# shellcheck disable=SC2218
git -C "$emitsafe_root/git/repo" config user.email test@example.com
# shellcheck disable=SC2218
git -C "$emitsafe_root/git/repo" config user.name "DXE Test"
printf 'content\n' > "$emitsafe_root/git/repo/file.txt"
# shellcheck disable=SC2218
git -C "$emitsafe_root/git/repo" add -A
# shellcheck disable=SC2218
git -C "$emitsafe_root/git/repo" commit -q -m initial
emitsafe_target="$emitsafe_root/git/repo"
git() {
    case "$*" in
        *"$emitsafe_target ls-files"*) return 1 ;;
        *) command git "$@" ;;
    esac
}
emitsafe_out="$FIXTURE/emitsafe-out.tsv"
emitsafe_stderr="$FIXTURE/emitsafe-stderr.log"
emitsafe_tmp_before="$(dxe_pbs_emitsafe_tmp_count)"
set +e
dx_pbs_emit_repo_safe "$emitsafe_target" repo reason > "$emitsafe_out" 2> "$emitsafe_stderr"
emitsafe_rc=$?
set -e
emitsafe_tmp_after="$(dxe_pbs_emitsafe_tmp_count)"
unset -f git
if [ "$emitsafe_rc" -ne 0 ]; then
    test_pass "dx_pbs_emit_repo_safe reports failure when git ls-files fails in --with-reason mode (dx-persist-backup-select.sh:523-525)"
else
    test_fail "dx_pbs_emit_repo_safe reports failure when git ls-files fails in --with-reason mode (dx-persist-backup-select.sh:523-525)"
fi
if grep -Fq "Error: git ls-files failed:" "$emitsafe_stderr" && grep -Fq "$emitsafe_target" "$emitsafe_stderr"; then
    test_pass "the git-ls-files failure names the repository in an Error: line"
else
    test_fail "the git-ls-files failure names the repository in an Error: line (stderr: $(cat "$emitsafe_stderr"))"
fi
if [ "$emitsafe_tmp_before" = "$emitsafe_tmp_after" ]; then
    test_pass "dx_pbs_emit_repo_safe's git-ls-files failure leaves no temp file behind"
else
    test_fail "dx_pbs_emit_repo_safe's git-ls-files failure leaves no temp file behind (before=$emitsafe_tmp_before after=$emitsafe_tmp_after)"
fi
rm -rf "$emitsafe_root"

print_summary
exit_with_code
