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

# --- Fixture: repo-a -- has a remote, HEAD is pushed, then gains local,
# uncommitted changes of every kind the rules must catch. ---
mkdir -p "$FIXTURE/remotes"
git init -q --bare "$FIXTURE/remotes/repo-a.git"
git_repo "$FIXTURE/persist/git/repo-a"
printf 'unchanged\n' > "$FIXTURE/persist/git/repo-a/unchanged.txt"
printf 'original\n' > "$FIXTURE/persist/git/repo-a/modified.txt"
mkdir -p "$FIXTURE/persist/git/repo-a/node_modules/pkg"
printf 'dep\n' > "$FIXTURE/persist/git/repo-a/node_modules/pkg/index.js"
git -C "$FIXTURE/persist/git/repo-a" add -A
git -C "$FIXTURE/persist/git/repo-a" commit -q -m "initial"
git -C "$FIXTURE/persist/git/repo-a" remote add origin "$FIXTURE/remotes/repo-a.git"
git -C "$FIXTURE/persist/git/repo-a" push -q origin main
# Now make it dirty in every way the rules must catch.
printf 'changed\n' > "$FIXTURE/persist/git/repo-a/modified.txt"
printf 'brand new\n' > "$FIXTURE/persist/git/repo-a/staged-new.txt"
git -C "$FIXTURE/persist/git/repo-a" add staged-new.txt
printf 'untracked\n' > "$FIXTURE/persist/git/repo-a/untracked.txt"
printf 'secret.local\n' > "$FIXTURE/persist/git/repo-a/.gitignore"
git -C "$FIXTURE/persist/git/repo-a" add .gitignore
printf 'do-not-lose-me\n' > "$FIXTURE/persist/git/repo-a/secret.local"
printf 'rebuildable\n' > "$FIXTURE/persist/git/repo-a/node_modules/pkg/new-dep.js"

# --- Fixture: repo-b -- pushed once, then a LOCAL-ONLY commit on top: the
# whole repository (including .git) must be treated as at-risk. ---
git init -q --bare "$FIXTURE/remotes/repo-b.git"
git_repo "$FIXTURE/persist/git/repo-b"
printf 'one\n' > "$FIXTURE/persist/git/repo-b/file.txt"
git -C "$FIXTURE/persist/git/repo-b" add -A
git -C "$FIXTURE/persist/git/repo-b" commit -q -m "initial"
git -C "$FIXTURE/persist/git/repo-b" remote add origin "$FIXTURE/remotes/repo-b.git"
git -C "$FIXTURE/persist/git/repo-b" push -q origin main
printf 'two\n' >> "$FIXTURE/persist/git/repo-b/file.txt"
git -C "$FIXTURE/persist/git/repo-b" commit -q -am "local-only commit"

# --- Fixture: repo-c -- no remote at all: at-risk as a whole even though
# everything is committed and the tree is otherwise clean. ---
git_repo "$FIXTURE/persist/git/repo-c"
printf 'clean\n' > "$FIXTURE/persist/git/repo-c/clean.txt"
git -C "$FIXTURE/persist/git/repo-c" add -A
git -C "$FIXTURE/persist/git/repo-c" commit -q -m "only commit, no remote"

# --- Loose file outside any repository. ---
mkdir -p "$FIXTURE/persist/home/dx"
printf 'history\n' > "$FIXTURE/persist/home/dx/.bash_history"

# --- Deny-listed cache dir OUTSIDE any repository. ---
mkdir -p "$FIXTURE/persist/home/dx/.cache/pip"
printf 'cache\n' > "$FIXTURE/persist/home/dx/.cache/pip/wheel"

# --- Nix-profile generations tree: denied by the built-in path pattern. ---
mkdir -p "$FIXTURE/persist/home/dx/.local/state/dx-ai/generations/7"
ln -s /nix/store/does-not-matter "$FIXTURE/persist/home/dx/.local/state/dx-ai/generations/7/profile"

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

# Outside any repository.
assert_listed "home/dx/.bash_history" "a file outside any repository is always at-risk"
assert_not_listed "home/dx/.cache/pip/wheel" "a deny-listed cache dir outside any repository is excluded"
assert_not_listed "home/dx/.local/state/dx-ai/generations/7/profile" "the Nix-profile generations tree is excluded by the built-in path pattern"
assert_not_listed "scratch/throwaway.tmp" "DX_BACKUP_EXCLUDE_FILE-style user pattern is honoured"

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

# --- dx_pbs_repo_at_risk_whole: direct unit-level checks. ---
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-a"; then test_fail "repo-a (pushed, clean HEAD) is not at-risk as a whole"; else test_pass "repo-a (pushed, clean HEAD) is not at-risk as a whole"; fi
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-b"; then test_pass "repo-b (unpushed commit) is at-risk as a whole"; else test_fail "repo-b (unpushed commit) is at-risk as a whole"; fi
if dx_pbs_repo_at_risk_whole "$FIXTURE/persist/git/repo-c"; then test_pass "repo-c (no remote) is at-risk as a whole"; else test_fail "repo-c (no remote) is at-risk as a whole"; fi

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

print_summary
exit_with_code
