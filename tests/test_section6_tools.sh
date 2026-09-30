#!/bin/bash
# tier: unit
# bash32: no
# Section 6: Improve Guest Tooling
# Tests for: diagnostic tools, basic utilities in flake.nix

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
dxe_require_tmux_probes

test_section "Section 6: Improve Guest Tooling"

TOOLS_NIX="$CONTAINER_DIR/home/tools.nix"
DX_AI_SCRIPT="$CONTAINER_DIR/scripts/dx-ai.sh"
DX_HERDR_NAV_SCRIPT="$CONTAINER_DIR/scripts/dx-herdr-navigate.sh"
DX_VERIFY_INVENTORY_SCRIPT="$CONTAINER_DIR/scripts/dx-verify-inventory.sh"
# WP7.3 (docs/reviews/2026-09-29-fable.md finding C3, Muse B4): the one
# nixpkgs-attribute -> command mapping flake.nix's dxPackages and
# requiredInventory (checks.inventory, checks.inventory-list) are both
# generated from.
GUEST_TOOLS_NIX="$CONTAINER_DIR/guest-tools.nix"

# Test: flake.nix exists
assert_file_exists "$FLAKE_NIX" "flake.nix exists"

# Test: the guest flake must not fetch unpinned mutable URLs -- the
# testImage fixture pulled a GitHub avatar (a URL whose bytes change behind
# the same address) and broke Home Manager evaluation the moment upstream
# re-rendered it. Guard against reintroducing that shape rather than banning
# `fetchurl` outright: agy's derivation above also calls `pkgs.fetchurl`, but
# against a versioned release tarball URL pinned via pins/agy.json, which is
# not a mutable resource. Evaluation (home.file has no test-image.png) and
# the fresh-guest build are the actual behaviour checks; this is a
# source-shape regression guard only.
assert_file_not_contains "$FLAKE_NIX" "avatars.githubusercontent.com" "guest flake does not fetch the mutable GitHub avatar URL"

# Test: nixpkgs-unstable tracks the cached nixpkgs-unstable channel branch, not
# master. Master is ahead of Hydra's binary cache, so an AI-tools refresh
# staged from a master revision can land on packages that are not yet cached
# for the guest's architecture, and Nix silently builds them from source
# instead (found on Branch 6, 2026-09-26: codex-core/codex-tui OOM-killed at
# the profile's default 12 GB). The nixpkgs-unstable branch only advances
# after Hydra has built it, so it is cached on cache.nixos.org for both
# aarch64-linux and x86_64-linux.
assert_file_contains_literal "$FLAKE_NIX" 'nixpkgs-unstable.url = "github:nixos/nixpkgs/nixpkgs-unstable"' "nixpkgs-unstable input tracks the cached channel branch, not master"
assert_file_not_contains "$FLAKE_NIX" 'nixpkgs-unstable.url = "github:nixos/nixpkgs/master"' "nixpkgs-unstable input no longer tracks nixpkgs master"

# WP7.3: dxPackages is generated from guest-tools.nix
# (`map (n: pkgs.${n}) (lib.attrNames guestTools)`), so it is no longer a
# literal list in flake.nix for these per-package checks to scan -- the
# mapping file is the new source of truth (Fable C3). Behaviourally, the
# real proof that every one of these still resolves to an installed
# command is checks.<system>.inventory / inventory-list below (nix eval,
# skipped on a host with no nix, like the rest of this block).
assert_file_exists "$GUEST_TOOLS_NIX" "guest-tools.nix mapping exists"

# Test: coreutils in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "coreutils" "coreutils in guest-tools.nix"

# Test: gnused in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "gnused" "gnused in guest-tools.nix"

# Test: gnugrep in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "gnugrep" "gnugrep in guest-tools.nix"

# Test: findutils in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "findutils" "findutils in guest-tools.nix"

# Test: procps in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "procps" "procps in guest-tools.nix"

# Test: util-linux in guest-tools.nix
assert_file_contains "$GUEST_TOOLS_NIX" "util-linux" "util-linux in guest-tools.nix"

# Test: less in guest-tools.nix (optional)
if grep -q "less" "$GUEST_TOOLS_NIX"; then
    test_pass "less in guest-tools.nix"
else
    test_skip "less not in guest-tools.nix (optional)"
fi

# Test: man-db is no longer a dxPackages entry -- it duplicated Home
# Manager's own manual.manpages.enable default (proven with `nix eval
# .../config.home.packages` before this fix: man-db appeared twice). `man`
# is still a required, verified command -- see requiredInventory's manual
# "man" entry in flake.nix and checks.<system>.inventory below.
assert_file_not_contains "$GUEST_TOOLS_NIX" "^[[:space:]]*man-db[[:space:]]*=" "man-db is not a guest-tools.nix entry (Home Manager's manual.manpages default already provides it)"

# Test: file in guest-tools.nix (optional)
if grep -q "file" "$GUEST_TOOLS_NIX"; then
    test_pass "file in guest-tools.nix"
else
    test_skip "file not in guest-tools.nix (optional)"
fi

# Test: git and tmux are configured through their typed Home Manager
# options, not a second, duplicate dxPackages entry (proven with `nix eval
# .../config.home.packages` before this fix: both appeared twice).
assert_file_contains "$TOOLS_NIX" "programs.git" "git preserved via programs.git (home/tools.nix), not a duplicate dxPackages entry"
assert_file_contains "$TOOLS_NIX" "programs.tmux" "tmux preserved via programs.tmux (home/tools.nix), not a duplicate dxPackages entry"
assert_grep_in_file "$GUEST_TOOLS_NIX" "^[[:space:]]*nix[[:space:]]*=" "nix preserved in guest-tools.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "openssh" "openssh preserved in guest-tools.nix"
assert_grep_in_file "$FLAKE_NIX" "nixvim" "nixvim preserved in flake.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "ripgrep" "ripgrep preserved in guest-tools.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "^[[:space:]]*fd[[:space:]]*=" "fd preserved in guest-tools.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "^[[:space:]]*curl[[:space:]]*=" "curl preserved in guest-tools.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "^[[:space:]]*jq[[:space:]]*=" "jq preserved in guest-tools.nix"
if grep -Eq "^[[:space:]]*gh[[:space:]]*=" "$GUEST_TOOLS_NIX"; then
    test_pass "GitHub CLI is in guest-tools.nix"
else
    test_fail "GitHub CLI is in guest-tools.nix"
fi
# WP7.4: direnv, yazi and lazygit moved from guest-tools.nix to typed
# programs.* options (programs.direnv also supplies nix-direnv via its own
# nix-direnv.enable, so neither key stays in the mapping -- adding them
# back would reintroduce the exact config.home.packages duplication WP7.3
# closed).
assert_file_contains "$SHELL_NIX" "programs.direnv" "direnv preserved via programs.direnv (home/shell.nix), not a duplicate dxPackages entry"
assert_file_contains "$SHELL_NIX" "programs.yazi" "yazi preserved via programs.yazi (home/shell.nix), not a duplicate dxPackages entry"
assert_file_contains "$TOOLS_NIX" "programs.lazygit" "lazygit preserved via programs.lazygit (home/tools.nix), not a duplicate dxPackages entry"
assert_file_not_contains "$GUEST_TOOLS_NIX" "^[[:space:]]*nix-direnv[[:space:]]*=" "nix-direnv is not a guest-tools.nix entry (programs.direnv.nix-direnv.enable already provides it)"
assert_grep_in_file "$GUEST_TOOLS_NIX" "^[[:space:]]*just[[:space:]]*=" "just preserved in guest-tools.nix"
assert_grep_in_file "$GUEST_TOOLS_NIX" "go-task" "go-task preserved in guest-tools.nix"
assert_file_contains "$TOOLS_NIX" "set -g display-panes-time 3000" "tmux display panes timeout is 3s"
# base-index migrated from a raw `set -g base-index 1` string to the typed
# Home Manager option. Runtime behaviour is asserted in the live block below.
assert_file_contains "$TOOLS_NIX" "baseIndex = 1;" "tmux base-index is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" 'keyMode = "vi";' "tmux key mode is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" "set -g status-keys emacs" "tmux keeps emacs status-keys despite vi keyMode"
assert_file_contains "$TOOLS_NIX" "customPaneNavigationAndResize = true;" "tmux pane navigation/resize is wired as a typed Home Manager option"
assert_file_contains "$TOOLS_NIX" "disableConfirmationPrompt = true;" "tmux kill-pane/window skip the confirmation prompt via typed option"
assert_file_contains "$TOOLS_NIX" "sensibleOnTop = true;" "tmux loads tmux-sensible defaults beneath the typed options"
assert_file_contains "$TOOLS_NIX" "plugin = resurrect;" "tmux-resurrect is declared as a Home Manager tmux plugin"
assert_file_contains "$TOOLS_NIX" "@resurrect-dir '/persist/home/dx/.local/share/tmux/resurrect'" "tmux-resurrect saves to the persisted directory"
assert_file_contains "$TOOLS_NIX" "plugin = continuum;" "tmux-continuum is declared as a Home Manager tmux plugin"
assert_file_contains "$TOOLS_NIX" "@continuum-restore 'on'" "tmux-continuum restores sessions on server start"
assert_file_contains "$TOOLS_NIX" "@continuum-save-interval" "tmux-continuum auto-saves on an interval"

# vim-tmux-navigator: prefix-less Ctrl-h/j/k/l across tmux panes and nvim splits.
NAV_NVIM_NIX="$CONTAINER_DIR/nvim/plugins/vim-tmux-navigator.nix"
NIXVIM_NIX="$CONTAINER_DIR/nixvim.nix"
assert_file_contains "$TOOLS_NIX" "vim-tmux-navigator" "tmux side of vim-tmux-navigator is declared in tmux plugins"
assert_file_exists "$NAV_NVIM_NIX" "Neovim side of vim-tmux-navigator is a self-contained module"
assert_file_contains "$NAV_NVIM_NIX" "TmuxNavigateLeft" "Neovim navigator maps Ctrl-h to TmuxNavigateLeft"
assert_file_contains "$NIXVIM_NIX" "vim-tmux-navigator.nix" "Neovim navigator module is imported by nixvim"
assert_file_exists "$DX_HERDR_NAV_SCRIPT" "Herdr pane navigator helper exists"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane process-info" "Herdr navigator inspects the foreground pane process"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane send-keys" "Herdr navigator forwards Ctrl navigation into Neovim"
assert_file_contains "$DX_HERDR_NAV_SCRIPT" "pane focus" "Herdr navigator focuses adjacent Herdr panes"
# WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): dx-herdr-navigate is
# now installed via the dxScript/mapAttrs' table (home/tools.nix), so its
# destination path ".local/bin/dx-herdr-navigate" is generated from the
# attribute name below rather than appearing as that literal string.
assert_file_contains "$TOOLS_NIX" "dx-herdr-navigate = {" "Herdr navigator helper is installed by Home Manager"
assert_file_contains "$TOOLS_NIX" "dx-herdr-navigator.lua" "Herdr-aware Neovim edge navigation is installed by Home Manager"
if bash -n "$DX_HERDR_NAV_SCRIPT" 2>/dev/null; then
    test_pass "Herdr navigator helper passes bash syntax check"
else
    test_fail "Herdr navigator helper passes bash syntax check"
fi
assert_file_contains "$TOOLS_NIX" "set -g renumber-windows on" "tmux renumbers windows on close"
assert_file_contains "$TOOLS_NIX" "set-option -g main-pane-width 50%" "tmux main pane width is 50 percent"
assert_file_contains "$TOOLS_NIX" 'bind -N "Switch to tiled layout" + select-layout tiled' "tmux prefix plus selects tiled layout"
assert_file_contains "$TOOLS_NIX" 'bind -N "Promote selected pane to main pane" a select-layout main-vertical' "tmux prefix a selects main-vertical layout"
assert_file_contains "$TOOLS_NIX" "display-panes \"swap-pane -s .%% -t .1" "tmux prefix-a shows pane picker that swaps into the main pane"
assert_file_contains_literal "$TOOLS_NIX" \
    'bind -N "Choose window with activity or bell" b choose-tree -Zw -f "#{||:#{window_activity_flag},#{window_bell_flag}}"' \
    "tmux activity picker remains bound on prefix-b"

# WP7.4 (docs/reviews/2026-09-29-fable.md finding C4): the yazi `y`
# cd-on-exit wrapper used to be a hand-rolled function in each of the three
# shell blocks (bash/fish/nushell) in this file. programs.yazi's typed
# shellWrapperName option now generates it for all three, so the real
# behavioural proof is checks.<shell>-integration below (nix build), not a
# text match against a function body this file no longer contains.
assert_file_contains "$SHELL_NIX" 'shellWrapperName = "y"' "yazi cd-on-exit wrapper is named y via the typed shellWrapperName option"
assert_file_contains "$SHELL_NIX" "programs.yazi" "yazi shell integration is configured via the typed programs.yazi option"
assert_file_contains "$SHELL_NIX" "enableBashIntegration = true" "yazi/direnv/starship bash integration is explicitly enabled"
assert_file_contains "$SHELL_NIX" "enableFishIntegration = true" "yazi/direnv/starship fish integration is explicitly enabled"
assert_file_contains "$SHELL_NIX" "enableNushellIntegration = true" "yazi/direnv/starship nushell integration is explicitly enabled"

# Test: AI CLI tools are excluded from the default dxPackages/guest-tools.nix list
if stdin_matches -E "codex|gemini-cli|claude-code|antigravity-cli|opencode" < "$GUEST_TOOLS_NIX"; then
    test_fail "AI CLI tools excluded from guest-tools.nix (dxPackages)"
else
    test_pass "AI CLI tools excluded from guest-tools.nix (dxPackages)"
fi

# Test: AI CLI tools are available through an opt-in package output
AI_PACKAGES_BLOCK="$(awk '
    /aiPackages =/ { in_block = 1 }
    in_block { print }
    in_block && /^[[:space:]]*\];[[:space:]]*$/ { exit }
' "$FLAKE_NIX")"

assert_file_contains "$FLAKE_NIX" "aiPackages =" "aiPackages list exists"
assert_file_contains "$FLAKE_NIX" '"ai-tools"' "ai-tools package output exists"
assert_grep_in_file "$FLAKE_NIX" "paths = aiPackages;" "ai-tools package uses aiPackages"
assert_grep_in_file "$FLAKE_NIX" "aiPackages = with unstable;" "aiPackages use unstable package set"
assert_file_exists "$DX_AI_SCRIPT" "guest dx-ai script exists"
if git -C "$BASE_DIR" ls-files --error-unmatch "${DX_AI_SCRIPT#$BASE_DIR/}" >/dev/null 2>&1; then
    test_pass "guest dx-ai script is tracked for flake source inclusion"
else
    test_fail "guest dx-ai script is tracked for flake source inclusion"
fi
assert_file_contains "$TOOLS_NIX" ".local/bin/dx-ai" "guest dx-ai command is installed by Home Manager"

if bash -n "$DX_AI_SCRIPT" 2>/dev/null; then
    test_pass "guest dx-ai script passes bash syntax check"
else
    test_fail "guest dx-ai script passes bash syntax check"
fi

# WP8.2 (commit 2cd212b) split dx-ai.sh's nixpkgs-unstable refresh, agy-pin
# handling, and post-install credential setup out into
# scripts/lib/dx-ai-{generation,pin,post-install}.sh. The text these seven
# cases used to grep for now lives in those library files as real function
# bodies, not in $DX_AI_SCRIPT's own text -- source the real script once
# (the same eager-load chain tests/test_section17_dx_ai_runtime.sh relies
# on: dx-ai.sh's own dx_ai_bootstrap_load pulls in dx-ai-generation.sh,
# dx-ai-pin.sh and dx-ai-post-install.sh eagerly) and drive its real
# functions with the same narrow curl/nix stand-ins that suite uses,
# instead of grepping for text that moved out from under these assertions.
# shellcheck source=/dev/null
source "$DX_AI_SCRIPT"

# dx_ai_update_flake (scripts/lib/dx-ai-generation.sh) refreshes the agy pin
# THEN updates nixpkgs-unstable -- log both stand-ins' invocations in call
# order and prove both properties from the one real call: the
# nixpkgs-unstable update actually happens, and the agy-manifest refresh
# happens first (dx_ai_main_update, dx-ai.sh, unchanged by this split,
# always finishes dx_ai_update_flake before it ever calls
# dx_ai_install_profile, so "first" here is also "before install").
AGY_UPDATE_FLAKE_LOG="$(mktemp "${TMPDIR:-/tmp}/dxe-s6-update-flake.XXXXXX")"
AGY_UPDATE_FLAKE_STAGE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-s6-update-flake-stage.XXXXXX")"
(
    dx_ai_refresh_pin() { printf 'refresh-pin\n' >> "$AGY_UPDATE_FLAKE_LOG"; }
    nix() { printf '%s\n' "$*" >> "$AGY_UPDATE_FLAKE_LOG"; }
    dx_ai_update_flake "$AGY_UPDATE_FLAKE_STAGE" aarch64-linux
) >/dev/null
if grep -q "flake update.*nixpkgs-unstable" "$AGY_UPDATE_FLAKE_LOG"; then
    test_pass "guest dx-ai updates nixpkgs-unstable"
else
    test_fail "guest dx-ai updates nixpkgs-unstable"
fi
if [ "$(head -n1 "$AGY_UPDATE_FLAKE_LOG")" = "refresh-pin" ]; then
    test_pass "guest dx-ai refreshes the agy manifest before install"
else
    test_fail "guest dx-ai refreshes the agy manifest before install"
fi
rm -rf "$AGY_UPDATE_FLAKE_STAGE"
rm -f "$AGY_UPDATE_FLAKE_LOG"

# Branch 11 / Phase 4 (docs/refactor/arch-neutral-guest.md section 3): the
# single flat AGY_MANIFEST_URL constant became a per-system function --
# deliberate, not a regression (AGY_MANIFEST_URL had no consumer outside
# this one static assertion; confirmed by grep across the tree). Call the
# real dx_ai_agy_manifest_url (scripts/lib/dx-ai-pin.sh) directly: a pure
# dispatch with no side effects, so no stand-ins are needed.
if [ "$(dx_ai_agy_manifest_url aarch64-linux)" = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_arm64.json" ] \
    && [ "$(dx_ai_agy_manifest_url x86_64-linux)" = "https://antigravity-cli-auto-updater-974169037036.us-central1.run.app/manifests/linux_amd64.json" ]; then
    test_pass "guest dx-ai resolves a per-system agy updater manifest URL"
else
    test_fail "guest dx-ai resolves a per-system agy updater manifest URL"
fi

# dx_ai_refresh_pin (scripts/lib/dx-ai-pin.sh): drive the real function
# against a fixture pin, with curl and nix stubbed (no real network fetch,
# and this host has no nix) -- jq is real (this host has jq), so the
# manifest-field extraction and the pin merge both run for real, not a
# hardcoded stand-in, the same way test_section17_dx_ai_runtime.sh's own
# generic-splice dx_ai_refresh_pin case does.
AGY_REFRESH_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/dxe-s6-agy-refresh.XXXXXX")"
mkdir -p "$AGY_REFRESH_ROOT/pins"
printf '%s\n' '{"aarch64-linux":{"version":"1.0.5","url":"https://example.invalid/old-arm","hash":"sha512-old"}}' \
    > "$AGY_REFRESH_ROOT/pins/agy.json"
AGY_REFRESH_SHA512_HEX="$(printf 'a%.0s' $(seq 1 128))"
AGY_REFRESH_NIX_LOG="$(mktemp "${TMPDIR:-/tmp}/dxe-s6-agy-refresh-nix.XXXXXX")"
(
    curl() { printf '%s\n' '{"version":"9.9.9","url":"https://example.invalid/new-arm","sha512":"'"$AGY_REFRESH_SHA512_HEX"'"}'; }
    nix() { if [ "$1" = hash ]; then printf '%s\n' "$*" >> "$AGY_REFRESH_NIX_LOG"; printf 'sha512-newarmhash\n'; else command nix "$@"; fi; }
    dx_ai_refresh_pin "$AGY_REFRESH_ROOT" aarch64-linux
) >/dev/null

if grep -qF "hash convert --hash-algo sha512 --to sri $AGY_REFRESH_SHA512_HEX" "$AGY_REFRESH_NIX_LOG"; then
    test_pass "guest dx-ai converts agy manifest hash to Nix SRI"
else
    test_fail "guest dx-ai converts agy manifest hash to Nix SRI"
fi
if [ "$(jq -r '.["aarch64-linux"].version' "$AGY_REFRESH_ROOT/pins/agy.json" 2>/dev/null)" = "9.9.9" ] \
    && [ "$(jq -r '.["aarch64-linux"].url' "$AGY_REFRESH_ROOT/pins/agy.json" 2>/dev/null)" = "https://example.invalid/new-arm" ] \
    && [ "$(jq -r '.["aarch64-linux"].hash' "$AGY_REFRESH_ROOT/pins/agy.json" 2>/dev/null)" = "sha512-newarmhash" ]; then
    test_pass "guest dx-ai updates the structured agy pin"
else
    test_fail "guest dx-ai updates the structured agy pin"
fi
rm -rf "$AGY_REFRESH_ROOT"
rm -f "$AGY_REFRESH_NIX_LOG"



# dx_ai_setup_credentials (scripts/lib/dx-ai-post-install.sh): drive the
# real function against an isolated fixture (never the real $HOME or
# /persist) and check its actual on-disk effect -- a freshly-created, valid
# empty JSON object, not merely the literal `printf` source line. macOS
# bash 3.2's ln lacks GNU's -T, so it is shimmed here exactly the way
# test_section17_dx_ai_runtime.sh's own creds_ln_shim does for the same
# reason (BSD ln rejects -sfnT outright).
CREDS_JSON_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-s6-creds-json.XXXXXX")"
CREDS_JSON_FIXTURE="$(cd "$CREDS_JSON_FIXTURE" && pwd -P)"
CREDS_JSON_PERSIST="$CREDS_JSON_FIXTURE/persist/home/dx"
CREDS_JSON_HOME="$CREDS_JSON_FIXTURE/home/dx"
mkdir -p "$CREDS_JSON_PERSIST" "$CREDS_JSON_HOME"
if (
    ln() { if [ "${1:-}" = -sfnT ]; then command ln -sfn "$2" "$3"; else command ln "$@"; fi; }
    dx_ai_setup_credentials "$CREDS_JSON_PERSIST" "$CREDS_JSON_HOME"
) >/dev/null 2>&1 && jq -e '. == {}' "$CREDS_JSON_PERSIST/.claude.json" >/dev/null 2>&1; then
    test_pass "guest dx-ai initializes empty Claude config as JSON"
else
    test_fail "guest dx-ai initializes empty Claude config as JSON"
fi
rm -rf "$CREDS_JSON_FIXTURE"

AGY_PIN="$CONTAINER_DIR/pins/agy.json"
assert_file_contains_literal "$AGY_PIN" '"version": "1.0.5"' "agy pin uses a version with OAuth persistence fixes"
assert_file_not_contains "$FLAKE_NIX" 'version = "1.0.0";' "agy derivation is not pinned to the OAuth persistence bug version"

# WP7.6 (docs/reviews/2026-09-29-fable.md finding C6, corrects Muse B6):
# checks.<system>.agy-pin-shape (a pure Nix assert, flake.nix) replaces the
# literal aarch64-linux-only URL/hash assertions this used to be -- those
# asserted nothing about x86_64-linux, so the version/URL/hash skew Muse B6
# read as undocumented drift was, in fact, the only state CI accepted. The
# shape check covers every per-system pin (sha512- prefix, version and arch
# named in the URL) and ignores the "note" key WP7.6 adds to record that
# today's version gap between systems is expected.
assert_file_contains_literal "$AGY_PIN" '"note"' "agy pin records why its per-system versions currently differ"
if command -v nix >/dev/null 2>&1; then
    for system in aarch64-linux x86_64-linux; do
        if nix build --no-write-lock-file --no-link "$CONTAINER_DIR#checks.$system.agy-pin-shape" 2>/dev/null; then
            test_pass "checks.$system.agy-pin-shape: every per-system agy pin is well-formed"
        else
            test_fail "checks.$system.agy-pin-shape: every per-system agy pin is well-formed"
        fi
    done
else
    test_skip "nix not available, skipping checks.aarch64-linux.agy-pin-shape"
    test_skip "nix not available, skipping checks.x86_64-linux.agy-pin-shape"
fi
# dx_ai_setup_credentials (scripts/lib/dx-ai-post-install.sh) mkdir -p's the
# persisted Antigravity CLI state directory under the persisted ~/.gemini --
# same real-function-and-fixture approach as the Claude JSON config case
# above, checking the actual directory dx-ai creates rather than its
# `mkdir -p` source line.
CREDS_AGY_FIXTURE="$(mktemp -d "${TMPDIR:-/tmp}/dxe-s6-creds-agy.XXXXXX")"
CREDS_AGY_FIXTURE="$(cd "$CREDS_AGY_FIXTURE" && pwd -P)"
CREDS_AGY_PERSIST="$CREDS_AGY_FIXTURE/persist/home/dx"
CREDS_AGY_HOME="$CREDS_AGY_FIXTURE/home/dx"
mkdir -p "$CREDS_AGY_PERSIST" "$CREDS_AGY_HOME"
if (
    ln() { if [ "${1:-}" = -sfnT ]; then command ln -sfn "$2" "$3"; else command ln "$@"; fi; }
    dx_ai_setup_credentials "$CREDS_AGY_PERSIST" "$CREDS_AGY_HOME"
) >/dev/null 2>&1 && [ -d "$CREDS_AGY_PERSIST/.gemini/antigravity-cli" ]; then
    test_pass "guest dx-ai prepares persisted agy state directory"
else
    test_fail "guest dx-ai prepares persisted agy state directory"
fi
rm -rf "$CREDS_AGY_FIXTURE"

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "codex"; then
    test_pass "codex is in aiPackages"
else
    test_fail "codex is in aiPackages"
fi

# findings.md's 2026-09-30 Progress log ("User decisions") records gemini-cli's
# removal from the optional AI tools bundle (Google retired the free/Pro-Ultra
# tier CLI in favour of Antigravity CLI; WP2.2 had kept it and acknowledged
# nixpkgs' removal notice, but the user decided to drop it rather than keep
# suppressing the warning). Two independent proofs it stays gone: the text of
# aiPackages itself (here), and the actual built package set further below
# (guarded by `command -v nix`, mirroring Section 5's checks.<system> loop) --
# either one alone could miss a re-add through an indirection the other
# doesn't see.
if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "gemini-cli"; then
    test_fail "gemini-cli is not in aiPackages"
else
    test_pass "gemini-cli is not in aiPackages"
fi

declared_ai_tools="$(sed -n 's/^DX_AI_TOOLS="\(.*\)"$/\1/p' "$DX_AI_SCRIPT")"
if printf '%s\n' " $declared_ai_tools " | stdin_matches -E ' gemini '; then
    test_fail "gemini is not in DX_AI_TOOLS"
else
    test_pass "gemini is not in DX_AI_TOOLS"
fi

if command -v nix >/dev/null 2>&1; then
    for ai_tools_system in aarch64-linux x86_64-linux; do
        if ai_tools_paths="$(nix eval --json --no-write-lock-file "$CONTAINER_DIR#packages.$ai_tools_system.ai-tools.paths" 2>&1)"; then
            if printf '%s\n' "$ai_tools_paths" | stdin_matches "gemini"; then
                test_fail "checks.$ai_tools_system ai-tools package set does not contain gemini-cli (${ai_tools_paths})"
            else
                test_pass "checks.$ai_tools_system ai-tools package set does not contain gemini-cli"
            fi
        else
            test_fail "checks.$ai_tools_system ai-tools package set does not contain gemini-cli (nix eval failed: ${ai_tools_paths})"
        fi
    done
else
    test_skip "nix not available, skipping ai-tools gemini-cli absence check (aarch64-linux)"
    test_skip "nix not available, skipping ai-tools gemini-cli absence check (x86_64-linux)"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "claude-code"; then
    test_pass "claude-code is in aiPackages"
else
    test_fail "claude-code is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bagy\b"; then
    test_pass "agy (Antigravity CLI) is in aiPackages"
else
    test_fail "agy (Antigravity CLI) is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bherdr\b"; then
    test_pass "herdr is in aiPackages"
else
    test_fail "herdr is in aiPackages"
fi

if printf '%s\n' "$AI_PACKAGES_BLOCK" | stdin_matches -E "\bopencode\b"; then
    test_pass "opencode is in aiPackages"
else
    test_fail "opencode is in aiPackages"
fi

# OpenCode persistence (migration, symlinks, ownership repair) is covered
# behaviorally by Section 17 and the dx-opencode-persistence.sh unit tests in
# test_sourceable_coverage.sh. A literal source-text assertion here would not
# exercise the real behaviour once that logic lives in the shared helper
# (scripts/lib/dx-opencode-persistence.sh) rather than inline in dx-ai.sh and
# activation.sh, so it is intentionally not duplicated as a text check.

# WP8.3: WP8.2/WP3.5 added seven guest libraries under scripts/lib/
# (dx-ai-lock.sh, dx-ai-loader.sh, dx-ai-generation.sh, dx-ai-pin.sh,
# dx-ai-cache-policy.sh, dx-ai-post-install.sh, dx-persist-relocate.sh) that
# dx-ai.sh's three-candidate loader (dx-ai-loader.sh's dx_ai_load_library)
# looks for under ~/.local/lib/dx/, but home/tools.nix never installed any
# of them there -- only dx-opencode-persistence.sh, dx-guest-system.sh and
# dx-keyring.sh had a hand-written `home.file` entry. home/tools.nix now
# installs every scripts/lib/*.sh (minus the one bootstrap-volume-only
# exclusion, dx-persist-backup-select.sh -- see that file's own comment)
# from a single builtins.readDir-driven table, so a static text check
# against a per-file literal would not prove anything a future library
# could still fall through; these two checks assert the mechanism itself
# and its real, evaluated result instead.
assert_file_contains "$TOOLS_NIX" "builtins.readDir guestLibDir" "home/tools.nix installs scripts/lib/*.sh from a builtins.readDir-driven table"
assert_file_contains "$TOOLS_NIX" 'dx-persist-backup-select.sh' "home/tools.nix documents its one guest-lib install exclusion"
assert_file_contains "$FLAKE_NIX" "guest-libs-installed = pkgs.runCommand" "flake.nix exposes the guest-libs-installed behavioural check"

# Eval-only (no build): home.file's attribute names are fully determined by
# evaluation alone (home.file entries are Nix values, not yet a built
# home-files derivation), so this proves -- without paying for a build --
# that every one of the seven newly-added libraries actually reaches a
# ".local/lib/dx/<name>" home.file entry on both systems. The real,
# built-and-diffed proof (installed content is byte-identical to its
# scripts/lib/ source) is checks.<system>.guest-libs-installed itself,
# exercised by Section 5's eval/warnings loop and by `nix build` directly.
DX_NEW_GUEST_LIBS=(
    dx-ai-lock.sh dx-ai-loader.sh dx-ai-generation.sh dx-ai-pin.sh
    dx-ai-cache-policy.sh dx-ai-post-install.sh dx-persist-relocate.sh
)
if command -v nix >/dev/null 2>&1; then
    for system in aarch64-linux x86_64-linux; do
        if home_file_names="$(nix eval --json --no-write-lock-file "$CONTAINER_DIR#homeConfigurations.dx-$system.config.home.file" --apply 'builtins.attrNames' 2>&1)"; then
            for lib in "${DX_NEW_GUEST_LIBS[@]}"; do
                if printf '%s\n' "$home_file_names" | stdin_matches -F ".local/lib/dx/$lib"; then
                    test_pass "homeConfigurations.dx-$system installs $lib under .local/lib/dx/"
                else
                    test_fail "homeConfigurations.dx-$system installs $lib under .local/lib/dx/"
                fi
            done
        else
            for lib in "${DX_NEW_GUEST_LIBS[@]}"; do
                test_fail "homeConfigurations.dx-$system installs $lib under .local/lib/dx/ (nix eval failed: ${home_file_names})"
            done
        fi
    done
else
    for system in aarch64-linux x86_64-linux; do
        for lib in "${DX_NEW_GUEST_LIBS[@]}"; do
            test_skip "nix not available, skipping homeConfigurations.dx-$system home.file check for $lib"
        done
    done
fi

# --- Branch 11 / Phase 4 (qnap-dxe-plan.md Phase 4 item 4, docs/refactor/
# arch-neutral-guest.md section 5): scripts/dx-verify-inventory.sh prints
# present/missing for the guest's required CLI inventory after bootstrap,
# on either architecture -- the coordinating session runs it via
# dx_runtime_exec at the exit gate (SSH into the QNAP guest is Phase 5's
# job, so the gate uses exec). ---
assert_file_exists "$DX_VERIFY_INVENTORY_SCRIPT" "guest inventory verifier script exists"
if git -C "$BASE_DIR" ls-files --error-unmatch "${DX_VERIFY_INVENTORY_SCRIPT#$BASE_DIR/}" >/dev/null 2>&1; then
    test_pass "guest inventory verifier script is tracked for flake source inclusion"
else
    test_fail "guest inventory verifier script is tracked for flake source inclusion"
fi
# WP7.5 (docs/reviews/2026-09-29-fable.md finding C5): see the
# dx-herdr-navigate comment above -- same dxScript/mapAttrs' table.
assert_file_contains "$TOOLS_NIX" "dx-verify-inventory = {" "guest inventory verifier command is installed by Home Manager"

if bash -n "$DX_VERIFY_INVENTORY_SCRIPT" 2>/dev/null; then
    test_pass "guest inventory verifier script passes bash syntax check"
else
    test_fail "guest inventory verifier script passes bash syntax check"
fi

# Behavioral: a crafted PATH with some, but not all, of the required tools
# present as fake executables. Proves the real present/missing report and
# exit code, not the specific inventory list (which may grow independently
# of this test).
inv_fixture="$(mktemp -d "${TMPDIR:-/tmp}/dxe-inventory-test.XXXXXX")"
trap 'rm -rf "$inv_fixture"' EXIT
inv_bin="$inv_fixture/bin"
mkdir -p "$inv_bin"
# Resolved once, before PATH is ever restricted below -- a bare `bash`
# invocation under a fully-replaced PATH would try to resolve the
# interpreter itself through that same restricted PATH and fail with
# "command not found" (exit 127), which is nonzero and so would silently
# pass the "exits non-zero when something is missing" assertion for the
# wrong reason.
inv_bash="$(command -v bash)"
DX_REQUIRED_INVENTORY="$("$inv_bash" "$DX_VERIFY_INVENTORY_SCRIPT" --print-inventory 2>/dev/null || true)"
inv_present=""
inv_missing=""
inv_index=0
for inv_tool in $DX_REQUIRED_INVENTORY; do
    inv_index=$((inv_index + 1))
    if [ $((inv_index % 2)) -eq 0 ]; then
        printf '#!/bin/sh\n' > "$inv_bin/$inv_tool"
        chmod 0755 "$inv_bin/$inv_tool"
        inv_present="$inv_present $inv_tool"
    else
        inv_missing="$inv_missing $inv_tool"
    fi
done
inv_rc=0
inv_out="$(PATH="$inv_bin" "$inv_bash" "$DX_VERIFY_INVENTORY_SCRIPT" 2>/dev/null)" || inv_rc=$?
inv_ok=true
for inv_tool in $inv_present; do
    printf '%s\n' "$inv_out" | stdin_matches -F "present: $inv_tool" || inv_ok=false
done
for inv_tool in $inv_missing; do
    printf '%s\n' "$inv_out" | stdin_matches -F "missing: $inv_tool" || inv_ok=false
done
if [ "$inv_ok" = true ] && [ -n "$inv_missing" ]; then
    test_pass "guest inventory verifier reports present/missing correctly for a mixed PATH"
else
    test_fail "guest inventory verifier reports present/missing correctly for a mixed PATH"
fi
if [ -n "$inv_missing" ] && [ "$inv_rc" -ne 0 ]; then
    test_pass "guest inventory verifier exits non-zero when any required tool is missing"
else
    test_fail "guest inventory verifier exits non-zero when any required tool is missing"
fi

# Every required tool present: exits 0.
inv_all_bin="$inv_fixture/bin-all"
mkdir -p "$inv_all_bin"
for inv_tool in $DX_REQUIRED_INVENTORY; do
    printf '#!/bin/sh\n' > "$inv_all_bin/$inv_tool"
    chmod 0755 "$inv_all_bin/$inv_tool"
done
if PATH="$inv_all_bin" "$inv_bash" "$DX_VERIFY_INVENTORY_SCRIPT" >/dev/null 2>&1; then
    test_pass "guest inventory verifier exits zero when every required tool is present"
else
    test_fail "guest inventory verifier exits zero when every required tool is present"
fi
rm -rf "$inv_fixture"
trap - EXIT

# WP7.4 (Fable C4): starship and direnv used to be guarded at runtime with
# `command -v`/`type -q` in hand-rolled shell blocks -- three different
# idioms, one of them (nushell) missing the hook entirely and undocumented.
# programs.starship.enable / programs.direnv.enable now own this: Home
# Manager only emits the init code when the option is enabled, so there is
# nothing left to guard, and it is emitted identically for all three shells.
assert_file_contains "$SHELL_NIX" "programs.starship = {" "starship is configured via the typed programs.starship option (bash/fish/nushell alike)"
assert_file_contains "$SHELL_NIX" "programs.direnv = {" "direnv is configured via the typed programs.direnv option (bash/fish/nushell alike)"
assert_file_contains "$SHELL_NIX" "nix-direnv.enable = true" "direnv uses the nix-direnv cache"
assert_file_not_contains "$SHELL_NIX" "command -v direnv" "bash no longer hand-guards the direnv hook (programs.direnv owns it)"
assert_file_not_contains "$SHELL_NIX" "command -v starship" "bash no longer hand-guards the starship hook (programs.starship owns it)"
assert_file_not_contains "$SHELL_NIX" "type -q direnv" "fish no longer hand-guards the direnv hook (programs.direnv owns it)"
assert_file_not_contains "$SHELL_NIX" "type -q starship" "fish no longer hand-guards the starship hook (programs.starship owns it)"

assert_file_contains "$SHELL_NIX" "agy = \\\"agy --dangerously-skip-permissions\\\"" "shell.nix configures agy with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "claude = \\\"claude --dangerously-skip-permissions\\\"" "shell.nix configures claude with --dangerously-skip-permissions"
assert_file_contains "$SHELL_NIX" "codex = \\\"codex --dangerously-bypass-approvals-and-sandbox\\\"" "shell.nix configures codex with --dangerously-bypass-approvals-and-sandbox"
assert_file_not_contains "$SHELL_NIX" "gemini = " "shell.nix no longer configures a gemini alias"

# --- Item 3 (fix/test-hardening): tmux_guest_resurrect_probe's live tmux- --
# --- resurrect check was timing-flaky (found on Branch 16's live tier,    -
# --- 2026-09-27, file untouched by that branch): it read @resurrect-dir   -
# --- and the C-s/C-r bindings exactly once, immediately after             -
# --- "new-session -d" returned, trusting that return meant the CONFIG-    -
# --- derived plugin state (tmux-resurrect/continuum, sourced via TPM as  -
# --- part of session start-up) had already settled -- probing server      -
# --- start-up timing rather than a settled state. Fixed in                -
# --- tests/lib/tmux-probes.sh: a bounded poll for all three observable    -
# --- conditions together, the same shape the OTHER probes in that file    -
# --- already use for their own bounded session-start retries. This is a  -
# --- live-tier probe with no real guest here, so the proof is the         -
# --- probe's own unit-level structure: a fake "tmux" on PATH that         -
# --- answers "not yet set/bound" for its first few calls and only the     -
# --- real values from a later call onward (a counter file, the same      -
# --- idiom Section 27's nc_retry uses -- see test_section27_qnap_scripts.sh),
# --- with container_exec_dx_bash temporarily overridden (saved via        -
# --- "declare -f" and restored immediately after, so nothing later in     -
# --- this file or the live block below is affected) to run the probe's   -
# --- own guest-side script body locally instead of through a real         -
# --- container. The coordinating session proves stability across three   -
# --- live dx-test runs afterward (this test cannot: there is no guest    -
# --- here to be flaky against). ---
RESURRECT_PROBE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dxe-resurrect-probe.XXXXXX")"
RESURRECT_COUNTER="$RESURRECT_PROBE_DIR/counter"
RESURRECT_SETTLE_AFTER=4
cat > "$RESURRECT_PROBE_DIR/tmux" <<'FAKETMUX'
#!/bin/bash
shift 2 # drop "-L" "<sock>": every call this probe makes has that shape
sub="$1"
case "$sub" in
    kill-server|new-session|set) exit 0 ;;
    show)
        n=0
        [ -f "$DXE_TEST_RESURRECT_COUNTER" ] && n="$(cat "$DXE_TEST_RESURRECT_COUNTER")"
        n=$((n + 1))
        printf "%s" "$n" > "$DXE_TEST_RESURRECT_COUNTER"
        [ "$n" -ge "$DXE_TEST_RESURRECT_SETTLE_AFTER" ] && echo "/persist/home/dx/.local/share/tmux/resurrect"
        exit 0
        ;;
    list-keys)
        n=0
        [ -f "$DXE_TEST_RESURRECT_COUNTER" ] && n="$(cat "$DXE_TEST_RESURRECT_COUNTER")"
        if [ "$n" -ge "$DXE_TEST_RESURRECT_SETTLE_AFTER" ]; then
            printf 'bind-key -T prefix C-s run-shell "resurrect_save.sh"\n'
            printf 'bind-key -T prefix C-r run-shell "resurrect_restore.sh"\n'
        fi
        exit 0
        ;;
esac
exit 0
FAKETMUX
chmod +x "$RESURRECT_PROBE_DIR/tmux"

RESURRECT_ORIG_CONTAINER_EXEC_DX_BASH="$(declare -f container_exec_dx_bash)"
container_exec_dx_bash() {
    DXE_TEST_RESURRECT_COUNTER="$RESURRECT_COUNTER" DXE_TEST_RESURRECT_SETTLE_AFTER="$RESURRECT_SETTLE_AFTER" \
        PATH="$RESURRECT_PROBE_DIR:$PATH" bash -c "$1"
}
RESURRECT_PROBE_OUT="$(tmux_guest_resurrect_probe)"
eval "$RESURRECT_ORIG_CONTAINER_EXEC_DX_BASH"
rm -rf "$RESURRECT_PROBE_DIR"

assert_tmux_runtime "$RESURRECT_PROBE_OUT" resurrect-dir /persist/home/dx/.local/share/tmux/resurrect "tmux resurrect probe polls until @resurrect-dir settles instead of reading it too early"
assert_tmux_runtime "$RESURRECT_PROBE_OUT" save-bound yes "tmux resurrect probe polls until the save binding settles instead of reading it too early"
assert_tmux_runtime "$RESURRECT_PROBE_OUT" restore-bound yes "tmux resurrect probe polls until the restore binding settles instead of reading it too early"

if [ "${SKIP_INTEGRATION:-false}" = true ]; then
    test_skip "guest tool live checks skipped by --skip-integration"
elif ! requires_container; then
    :
elif ! wait_for_ssh 60; then
    test_fail "SSH not reachable on localhost:$DX_SSH_PORT"
else
    for tool_check in \
        "nix --version" \
        "git --version" \
        "gh --version" \
        "tmux -V" \
        "yazi --version" \
        "lazygit --version" \
        "nvim --headless +q"
    do
        if guest_bash "$tool_check >/dev/null"; then
            test_pass "guest tool runs: $tool_check"
        else
            test_fail "guest tool runs: $tool_check"
        fi
    done

    # Behaviour: query the activated tmux config from a throwaway server inside
    # the guest, proving the typed Home Manager options actually take effect at
    # runtime (not merely that strings exist in tools.nix).
    TMUX_PROBE="$(tmux_guest_probe || true)"
    if printf '%s\n' "$TMUX_PROBE" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_PROBE" ]; then
        test_fail "tmux runtime probe started a server in the guest"
    else
        test_pass "tmux runtime probe started a server in the guest"
        assert_tmux_runtime "$TMUX_PROBE" base-index 1 "tmux windows use 1-based indexing"
        assert_tmux_runtime "$TMUX_PROBE" pane-base-index 1 "tmux panes use 1-based indexing"
        assert_tmux_runtime "$TMUX_PROBE" mouse on "tmux mouse mode is enabled"
        assert_tmux_runtime "$TMUX_PROBE" history-limit 50000 "tmux history limit is 50000"
        assert_tmux_runtime "$TMUX_PROBE" escape-time 0 "tmux escape-time is 0"
        assert_tmux_runtime "$TMUX_PROBE" focus-events on "tmux focus-events are enabled"
        assert_tmux_runtime "$TMUX_PROBE" default-terminal tmux-256color "tmux default-terminal is tmux-256color"
        assert_tmux_runtime "$TMUX_PROBE" mode-keys vi "tmux copy mode uses vi keys"
        assert_tmux_runtime "$TMUX_PROBE" status-keys emacs "tmux command prompt keeps emacs editing despite vi keyMode"
        assert_tmux_runtime "$TMUX_PROBE" set-clipboard on "tmux set-clipboard is on for OSC52 copy"
    fi

    # Behaviour: query the live prefix key table and pane-navigation effects.
    TMUX_KEYS="$(tmux_guest_keys_probe || true)"
    if printf '%s\n' "$TMUX_KEYS" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_KEYS" ]; then
        test_fail "tmux key-table probe started a server in the guest"
    else
        test_pass "tmux key-table probe started a server in the guest"
        # hjkl select panes in the right direction and are now repeatable.
        assert_tmux_runtime "$TMUX_KEYS" h.cmd "select-pane -L" "tmux prefix-h selects the left pane"
        assert_tmux_runtime "$TMUX_KEYS" j.cmd "select-pane -D" "tmux prefix-j selects the lower pane"
        assert_tmux_runtime "$TMUX_KEYS" k.cmd "select-pane -U" "tmux prefix-k selects the upper pane"
        assert_tmux_runtime "$TMUX_KEYS" l.cmd "select-pane -R" "tmux prefix-l selects the right pane"
        # The pinned Home Manager customPaneNavigationAndResize emits pane
        # SWITCH binds without -r (non-repeatable) and only the RESIZE binds
        # with -r. That preserves the prior hand-written behaviour, so assert
        # non-repeatable switching deliberately rather than the repeatable
        # switching the plan originally assumed this module would introduce.
        assert_tmux_runtime "$TMUX_KEYS" h.repeat no "tmux prefix-h pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" j.repeat no "tmux prefix-j pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" k.repeat no "tmux prefix-k pane switch is non-repeatable (HM module default)"
        assert_tmux_runtime "$TMUX_KEYS" l.repeat no "tmux prefix-l pane switch is non-repeatable (HM module default)"
        # HJKL resize panes and stay repeatable.
        assert_tmux_runtime_contains "$TMUX_KEYS" H.cmd "resize-pane -L" "tmux prefix-H resizes left"
        assert_tmux_runtime_contains "$TMUX_KEYS" L.cmd "resize-pane -R" "tmux prefix-L resizes right"
        assert_tmux_runtime "$TMUX_KEYS" H.repeat yes "tmux prefix-H resize is repeatable"
        assert_tmux_runtime "$TMUX_KEYS" L.repeat yes "tmux prefix-L resize is repeatable"
        # select-pane direction actually moves the active pane in the guest.
        assert_tmux_runtime "$TMUX_KEYS" pane-after-right 2 "tmux select-pane -R moves to the right pane"
        assert_tmux_runtime "$TMUX_KEYS" pane-after-left 1 "tmux select-pane -L moves to the left pane"
        # reload bind rebinds prefix-r to source the config, and it reloads cleanly.
        assert_tmux_runtime_contains "$TMUX_KEYS" r.cmd "source-file" "tmux prefix-r reloads the config"
        assert_tmux_runtime "$TMUX_KEYS" reload-sources-ok yes "tmux config sources without error"
        # disableConfirmationPrompt: prefix-x kills the pane with no confirm-before wrapper.
        assert_tmux_runtime_contains "$TMUX_KEYS" x.cmd "kill-pane" "tmux prefix-x kills the pane"
        assert_tmux_runtime_not_contains "$TMUX_KEYS" x.cmd "confirm-before" "tmux prefix-x skips the kill confirmation"
    fi

    # Behaviour: tmux-resurrect wiring and a real save/restore round trip.
    TMUX_RSR="$(tmux_guest_resurrect_probe || true)"
    if printf '%s\n' "$TMUX_RSR" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_RSR" ]; then
        test_fail "tmux resurrect probe started a server in the guest"
    else
        test_pass "tmux resurrect probe started a server in the guest"
        assert_tmux_runtime "$TMUX_RSR" dir-exists yes "resurrect save directory exists under /persist"
        assert_tmux_runtime "$TMUX_RSR" dir-writable yes "resurrect save directory is writable by dx"
        assert_tmux_runtime "$TMUX_RSR" resurrect-dir /persist/home/dx/.local/share/tmux/resurrect "resurrect @resurrect-dir points at the persisted path"
        assert_tmux_runtime "$TMUX_RSR" save-bound yes "resurrect save (prefix C-s) is bound"
        assert_tmux_runtime "$TMUX_RSR" restore-bound yes "resurrect restore (prefix C-r) is bound"

        # The full save/restore round trip writes into /persist and restarts
        # tmux servers, so gate it behind DX_TEST_DESTRUCTIVE to keep routine
        # runs side-effect free. Run it with DX_TEST_DESTRUCTIVE=1 (ideally in
        # an isolated profile) to validate end-to-end resurrect behaviour.
        if [ "${DX_TEST_DESTRUCTIVE:-0}" = "1" ]; then
            TMUX_RT="$(tmux_guest_resurrect_roundtrip || true)"
            assert_tmux_runtime "$TMUX_RT" save-file yes "resurrect writes a save file under the persisted dir"
            assert_tmux_runtime "$TMUX_RT" restored yes "resurrect restores a saved session after a server restart"
        else
            test_skip "resurrect save/restore round trip (set DX_TEST_DESTRUCTIVE=1 to run)"
        fi
    fi

    # sensibleOnTop must load beneath the typed options without overriding them.
    # The typed-option runtime values asserted in the first probe block above
    # (escape-time=0, history-limit=50000, default-terminal=tmux-256color,
    # base-index=1) double as the regression check that sensible did not win.

    # Behaviour: vim-tmux-navigator binds Ctrl-h/j/k/l in the tmux root table and
    # maps them in Neovim to the TmuxNavigate commands (seamless cross-nav itself
    # is a manual gate). Reads the live key table and headless nvim maps.
    TMUX_NAV="$(tmux_guest_navigator_probe || true)"
    if printf '%s\n' "$TMUX_NAV" | stdin_matches "__PROBE_FAILED__" || [ -z "$TMUX_NAV" ]; then
        test_fail "tmux navigator probe started a server in the guest"
    else
        test_pass "tmux navigator probe started a server in the guest"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-h yes "tmux root table binds Ctrl-h for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-j yes "tmux root table binds Ctrl-j for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-k yes "tmux root table binds Ctrl-k for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" tmux-root-C-l yes "tmux root table binds Ctrl-l for pane navigation"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-h yes "Neovim Ctrl-h resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-j yes "Neovim Ctrl-j resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-k yes "Neovim Ctrl-k resolves to TmuxNavigate (overrides the scroll alias)"
        assert_tmux_runtime "$TMUX_NAV" nvim-C-l yes "Neovim Ctrl-l resolves to TmuxNavigate"
    fi
fi

print_summary
exit_with_code
