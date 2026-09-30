#!/usr/bin/env bash
# dx-ai's own publication lock: a thin, dx-ai-specific wrapper over the
# shared guest publication-lock protocol (dx-publication.sh, a sibling file
# in this same directory -- WP5.2, docs/reviews/2026-09-29-fable.md B3,
# extends A3/Astra R3). Safe to source (import-only: defines functions,
# produces no output, and does not change caller control state).
#
# Branch 11 / Fable B3: moved out of dx-ai.sh so this logic sits under
# scripts/lib, in kcov's coverage scope (unlike scripts/*.sh, which is
# exempt -- see tests/coverage/exclusions.txt).
#
# WP5.2: this used to carry its OWN, independently written copy of the
# process-identity helpers and the lock loop -- a copy that had already
# drifted from the launcher's and the sync's (no grace period before
# reclaiming an ownerless lock directory, and a GNU-only `mv -T` for its
# stale-owner takeover). process_start, boot_id, publication_lock_acquire
# and publication_lock_release now live once, in dx-publication.sh, which
# this file sources as a plain sibling: the readDir-driven Nix table in
# home/tools.nix installs every scripts/lib/*.sh file together, so
# dx-publication.sh is always present next to this file, in every candidate
# location the three-candidate loader (dx-ai-loader.sh) can have resolved
# THIS file from. The functions below keep dx_ai_lock_acquire's own
# existing `<lock> <proc_root>` argument shape -- every caller and test of
# it is unchanged -- threading the proc root through as
# DX_LOCK_PROC_ROOT, a caller-local override of a name the shared functions
# never declare `local` themselves, so it is visible to them for the
# duration of the call (the same dynamic-scoping idiom
# bin/lib/dx-bootstrap-sync.sh's own dx_bootstrap_sync already relies on
# for its caller's `generation`/`outcome` locals).
# shellcheck source=./dx-publication.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/dx-publication.sh"

# shellcheck disable=SC2034 # DX_LOCK_PROC_ROOT/stat_line/stat_fields: read
# by process_start (dx-publication.sh), which never declares them `local`
# itself -- dynamic scoping, not dead code.
dx_ai_process_start() {
    local DX_LOCK_PROC_ROOT="${2:-/proc}" stat_line stat_fields
    process_start "$1"
}

# shellcheck disable=SC2034 # DX_LOCK_PROC_ROOT/dxgpp_*: read by boot_id
# (dx-publication.sh), which never declares them `local` itself -- dynamic
# scoping, not dead code.
dx_ai_boot_id() {
    local DX_LOCK_PROC_ROOT="${1:-/proc}" dxgpp_proc_root dxgpp_boot dxgpp_key dxgpp_value dxgpp_extra
    boot_id
}

# dx-ai has always hard-coded its own 30s timeout (no caller ever varied
# it); publication_lock_acquire's own second argument keeps that default.
# Every name publication_lock_acquire itself assigns without `local` is
# declared local here too, so none of it can reach up and overwrite a
# same-named variable in an already-local-scoped caller (dx_ai_run_locked's
# own `local lock`, in particular) -- it only ever touches ITS OWN copies.
# shellcheck disable=SC2034 # all read/written by publication_lock_acquire
# (dx-publication.sh) via dynamic scoping, not dead code.
dx_ai_lock_acquire() {
    local DX_LOCK_PROC_ROOT="${2:-/proc}"
    local lock timeout self_boot self_start elapsed owner_boot owner_pid owner_start live_start aside owner_tmp tab
    publication_lock_acquire "$1" 30
}

dx_ai_lock_release() { publication_lock_release "$1"; }
