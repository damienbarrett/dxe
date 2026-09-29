#!/bin/bash
# Remote Docker-over-SSH runtime adapter (Branch 11 / Phase 2,
# qnap-dxe-plan.md DQ1-DQ8). Every dx_runtime_docker_<op> function is
# DX_RUNTIME=docker-ssh's implementation of the matching dx_runtime_<op>
# contract operation (bin/lib/dx-runtime.sh), which dispatches to it exactly
# the way it dispatches to dx_runtime_apple_<op> for DX_RUNTIME=apple. See
# docs/refactor/docker-adapter-mapping.md for the full command-by-command
# design this file implements, and docs/refactor/runtime-boundary.md for the
# contract shape.
#
# DQ1: every remote invocation is a plain, non-interactive SSH command --
# `ssh -o BatchMode=yes ... <DX_REMOTE_HOST> <docker-abs-path> <verb> ...` --
# never Docker's own `-H ssh://` transport (Phase 0 confirmed it fails: the
# NAS's non-interactive PATH lacks `docker`, and Docker's ssh transport just
# runs `docker ...` on whatever that shell resolves). The Docker CLI's
# absolute path is discovered once per process and cached (the "Docker
# binary path discovery" section of dx-runtime-docker-identity.sh); nothing
# here re-derives it per call.
#
# Quoting discipline (see docs/refactor/docker-adapter-mapping.md section 1):
# SSH's exec channel has no real remote argv -- the client joins every
# trailing argument after the destination with one space and hands the
# result to the remote login shell to parse as ONE command line
# (tests/qnap/phase0-spike.sh hit this directly and fixed it the same way
# this file does). So every value that is not a fixed, author-written
# constant crosses through dx_runtime_docker_quote_argv, which %q-quotes
# each token individually before the tokens are joined with plain spaces --
# this is how "positional data, never interpolated executable text" (DQ1)
# is achieved over a transport that only ever accepts one string.
#
# Structured output (item 3): every query uses Docker's own `--format` Go
# templates to extract exactly the scalar field(s) needed (`{{.State.Running}}`,
# `{{index .Config.Labels "io.dxe.role"}}`, ...), never `docker ... | awk`
# table parsing and never a JSON blob that would need a JSON parser on the
# controller (the Mac side has no guaranteed `jq`; unlike the guest, which
# does, per its own flake). A handful of fields needed together are
# requested as one pipe-delimited template (e.g.
# `{{.ID}}|{{.Architecture}}`) so one ssh round trip yields all of them.
#
# This file is the facade every caller sources and dispatches through
# (bin/lib/dx-runtime.sh's own "source=dx-runtime-docker.sh" line, unchanged
# by the split below); it defines no functions of its own beyond sourcing
# its four implementation files, in the fixed order their own cross-file
# calls require: transport (the ssh/quoting primitives every other file
# calls), identity (discovery, the preflight chain, the daemon-identity
# cache, and the DQ6 label-verification/ownership checks), lifecycle
# (create/start/stop/kill/delete/exec/volumes/logs/export/run_ephemeral and
# the destructive plan), then lock (acquire/audit/release). Because every
# file below only defines functions and constants at import time (no
# execution), this fixed source order is enough for every cross-file call to
# resolve correctly once all four are loaded, regardless of which function a
# caller reaches first (WP8.3 step 3; findings.md, docs/reviews/
# 2026-09-29-muse.md A2, docs/reviews/2026-09-29-astra.md R3).
#
# Safe to source: defines functions and constants only, no I/O, no command
# dispatch, no shell options, at import time (same contract as
# dx-runtime-apple.sh and every other bin/lib/*.sh file).

DX_RUNTIME_DOCKER_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=dx-runtime-docker-transport.sh
source "$DX_RUNTIME_DOCKER_LIB_DIR/dx-runtime-docker-transport.sh"
# shellcheck source=dx-runtime-docker-identity.sh
source "$DX_RUNTIME_DOCKER_LIB_DIR/dx-runtime-docker-identity.sh"
# shellcheck source=dx-runtime-docker-lifecycle.sh
source "$DX_RUNTIME_DOCKER_LIB_DIR/dx-runtime-docker-lifecycle.sh"
# shellcheck source=dx-runtime-docker-lock.sh
source "$DX_RUNTIME_DOCKER_LIB_DIR/dx-runtime-docker-lock.sh"
