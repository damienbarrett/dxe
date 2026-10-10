#!/bin/bash
# tier: unit
# bash32: yes
# coverage: yes
set -uo pipefail

# WP4.1 acceptance: the /persist directory marker format (plan D-3, spec R16).
#
# Interface contract (container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh,
# POSIX sh, safe to source: functions only, no output, no shell options).
# bin/lib/dx-persist-dir.sh sources it the way bin/lib/dx-backup.sh sources
# the backup selector, so sourcing either file defines every function below.
#
#   File name: .dxe-persist-dir (constant DX_PERSIST_MARKER_NAME), at the
#   directory root. Text is key=value lines, one per line, each ending in a
#   newline. Canonical key order (fixed):
#       schema=1
#       guest=<name>
#       state=copying|ready|retired
#       source-volume=<volume>   (only when set)
#       created-at=<UTC>         (only when set)
#       migrated-at=<UTC>        (only when set)
#       retired-at=<UTC>         (only when set)
#   guest and source-volume match [A-Za-z0-9][A-Za-z0-9_.-]*; timestamps are
#   YYYY-MM-DDTHH:MM:SSZ with month 01-12, day 01-31, hour 00-23, minute and
#   second 00-59.
#
#   dx_persist_marker_format GUEST STATE [SOURCE_VOLUME [CREATED_AT
#       [MIGRATED_AT [RETIRED_AT]]]]
#     Positional; an empty string means "omit". Prints the canonical text on
#     stdout, returns 0. Invalid input (bad guest, state, volume or
#     timestamp) prints NOTHING on stdout, one line on stderr (reason
#     wording below) and returns 1.
#
#   dx_persist_marker_parse < TEXT
#     Reads marker text on STDIN (call it with a redirect or here-document,
#     not at the end of a pipe, so the variables survive). Blank lines are
#     ignored. Unknown keys are REJECTED. On success returns 0 and sets
#         DX_PERSIST_MARKER_GUEST, DX_PERSIST_MARKER_STATE,
#         DX_PERSIST_MARKER_SOURCE_VOLUME, DX_PERSIST_MARKER_CREATED_AT,
#         DX_PERSIST_MARKER_MIGRATED_AT, DX_PERSIST_MARKER_RETIRED_AT
#     (absent optional fields are the empty string). On failure returns 1,
#     prints exactly one line on stderr, nothing on stdout, and leaves all
#     six variables empty. The stderr line contains one of (fixed strings):
#         "unknown schema"      schema present but not 1
#         "missing schema"      "missing guest"     "missing state"
#         "unknown state"       "duplicate key"     "invalid guest"
#         "invalid source-volume"  "invalid timestamp"
#         "unknown key"         "malformed line" (no '=' or empty value)
#
#   dx_persist_marker_write DIR TEXT
#     Validates TEXT with the parser (invalid: returns non-zero, writes
#     nothing, creates no file). Otherwise writes TEXT to a temporary file
#     in DIR itself (a different name from the final one) and then runs
#     `mv <tmp> DIR/.dxe-persist-dir` (found via PATH, so it is stubbable).
#     Returns 0 on success, leaving only the marker in DIR. If mv fails it
#     removes the temporary file, leaves an existing marker untouched and
#     returns non-zero.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/test_helpers.sh"
test_section "WP4.1: /persist directory marker format"

LIB="$BASE_DIR/container/dx-nixos-26.05/scripts/lib/dx-persist-marker.sh"
HOSTLIB="$BASE_DIR/bin/lib/dx-persist-dir.sh"
TMP_ROOT="$(mktemp -d)"

# Nested probes run from real files (`bash "$PROBES/Pn.sh" ...`), never inline
# `bash -c '...'`: kcov injects code reading BASH_SOURCE, which is unset in an
# inline program and dies under `set -u` (same rule as test_refactor_contracts.sh).
PROBES="$TMP_ROOT/probes"; mkdir -p "$PROBES"
cat >"$PROBES/P0.sh" <<'PROBE'
before=$-; source "$1"; [ "$before" = "$-" ]
PROBE
cat >"$PROBES/P1.sh" <<'PROBE'
set -euo pipefail; before=$-; source "$1"; [ "$before" = "$-" ]
PROBE
cat >"$PROBES/P2.sh" <<'PROBE'
source "$1"; declare -F "$2" >/dev/null
PROBE
cat >"$PROBES/P3.sh" <<'PROBE'
source "$1"; printf "%s" "$DX_PERSIST_MARKER_NAME"
PROBE
cat >"$PROBES/P4.sh" <<'PROBE'
source "$1"; dx_persist_marker_format hostg ready
PROBE
cat >"$PROBES/P5.sh" <<'PROBE'
source "$1"; declare -F dx_persist_marker_write >/dev/null
PROBE
cat >"$PROBES/P6.sh" <<'PROBE'
source "$1"; dx_persist_marker_write "$2" "$3"
PROBE
trap 'rm -rf "$TMP_ROOT"' EXIT

assert_file_exists "$LIB" "the marker library exists"
assert_file_exists "$HOSTLIB" "the host module exists"

# Run a snippet in a fresh shell ($1 = shell, $2 = library, $3 = snippet).
run_in() {
    "$1" -c ". \"$2\"; $3" 2>&1
}

T_TS='2026-10-10T12:34:56Z'
T_TS2='2026-10-11T01:02:03Z'
T_TS3='2026-10-12T23:59:59Z'

for shell in /bin/bash sh; do
    command -v "$shell" >/dev/null 2>&1 || { test_skip "$shell not available"; continue; }
    label="[$shell]"

    # --- format ---
    out="$(run_in "$shell" "$LIB" 'dx_persist_marker_format dx-test ready')"
    expected="$(printf 'schema=1\nguest=dx-test\nstate=ready\n')"
    if [ "$out" = "$expected" ]; then test_pass "$label format prints the minimal canonical marker"; else test_fail "$label format prints the minimal canonical marker (got: $out)"; fi

    out="$(run_in "$shell" "$LIB" "dx_persist_marker_format dx-test retired my_vol.1 $T_TS $T_TS2 $T_TS3")"
    expected="$(printf 'schema=1\nguest=dx-test\nstate=retired\nsource-volume=my_vol.1\ncreated-at=%s\nmigrated-at=%s\nretired-at=%s\n' "$T_TS" "$T_TS2" "$T_TS3")"
    if [ "$out" = "$expected" ]; then test_pass "$label format emits every field in the fixed order"; else test_fail "$label format emits every field in the fixed order (got: $out)"; fi

    out="$(run_in "$shell" "$LIB" "dx_persist_marker_format g copying '' $T_TS '' $T_TS3")"
    expected="$(printf 'schema=1\nguest=g\nstate=copying\ncreated-at=%s\nretired-at=%s\n' "$T_TS" "$T_TS3")"
    if [ "$out" = "$expected" ]; then test_pass "$label format omits empty optional fields"; else test_fail "$label format omits empty optional fields (got: $out)"; fi

    for bad in "'' ready" "-bad ready" "'a b' ready" "'a/b' ready" "'a;b' ready" "g paused" "g ''" "g ready '-v'" "g ready '' 2026-10-10"; do
        out="$(run_in "$shell" "$LIB" "dx_persist_marker_format $bad 2>/dev/null")"; rc=$?
        errtxt="$(run_in "$shell" "$LIB" "dx_persist_marker_format $bad 2>&1 >/dev/null")"
        if [ -z "$out" ] && [ -n "$errtxt" ] && [ "$(printf '%s\n' "$errtxt" | wc -l | tr -d ' ')" = 1 ]; then
            test_pass "$label format refuses ($bad) with one stderr line and no stdout"
        else
            test_fail "$label format refuses ($bad) with one stderr line and no stdout (out='$out' err='$errtxt')"
        fi
        if ! "$shell" -c ". \"$LIB\" && command -v dx_persist_marker_format >/dev/null && ! dx_persist_marker_format $bad >/dev/null 2>&1"; then test_fail "$label format ($bad) returns non-zero"; else test_pass "$label format ($bad) returns non-zero"; fi
    done

    # --- round trip ---
    snippet="t=\$(dx_persist_marker_format Guest_1.x retired vol-9 $T_TS $T_TS2 $T_TS3) || exit 9
dx_persist_marker_parse <<EOT || exit 8
\$t
EOT
printf '%s|%s|%s|%s|%s|%s\n' \"\$DX_PERSIST_MARKER_GUEST\" \"\$DX_PERSIST_MARKER_STATE\" \"\$DX_PERSIST_MARKER_SOURCE_VOLUME\" \"\$DX_PERSIST_MARKER_CREATED_AT\" \"\$DX_PERSIST_MARKER_MIGRATED_AT\" \"\$DX_PERSIST_MARKER_RETIRED_AT\""
    out="$(run_in "$shell" "$LIB" "$snippet")"
    if [ "$out" = "Guest_1.x|retired|vol-9|$T_TS|$T_TS2|$T_TS3" ]; then test_pass "$label format then parse round-trips every field"; else test_fail "$label format then parse round-trips every field (got: $out)"; fi

    for st in copying ready retired; do
        snippet="t=\$(dx_persist_marker_format g1 $st) || exit 9
dx_persist_marker_parse <<EOT || exit 8
\$t
EOT
printf '%s|%s|%s|%s|%s|%s\n' \"\$DX_PERSIST_MARKER_GUEST\" \"\$DX_PERSIST_MARKER_STATE\" \"\$DX_PERSIST_MARKER_SOURCE_VOLUME\" \"\$DX_PERSIST_MARKER_CREATED_AT\" \"\$DX_PERSIST_MARKER_MIGRATED_AT\" \"\$DX_PERSIST_MARKER_RETIRED_AT\""
        out="$(run_in "$shell" "$LIB" "$snippet")"
        if [ "$out" = "g1|$st||||" ]; then test_pass "$label round trip state=$st leaves optional fields empty"; else test_fail "$label round trip state=$st leaves optional fields empty (got: $out)"; fi
    done

    # --- parse rejections: name|text|reason ---
    parse_case() { # name reason text
        local name="$1" reason="$2" text="$3" f="$TMP_ROOT/p.txt" out err rc
        printf '%b' "$text" >"$f"
        snippet="DX_PERSIST_MARKER_GUEST=stale DX_PERSIST_MARKER_STATE=stale
dx_persist_marker_parse <\"$f\"; rc=\$?
printf 'VARS=%s|%s|%s|%s|%s|%s\n' \"\$DX_PERSIST_MARKER_GUEST\" \"\$DX_PERSIST_MARKER_STATE\" \"\$DX_PERSIST_MARKER_SOURCE_VOLUME\" \"\$DX_PERSIST_MARKER_CREATED_AT\" \"\$DX_PERSIST_MARKER_MIGRATED_AT\" \"\$DX_PERSIST_MARKER_RETIRED_AT\" >&2
exit \$rc"
        out="$("$shell" -c ". \"$LIB\"; $snippet" 2>"$TMP_ROOT/err")"; rc=$?
        err="$(cat "$TMP_ROOT/err")"
        local reasonline; reasonline="$(printf '%s\n' "$err" | grep -v '^VARS=')"
        if [ "$rc" -ne 0 ] && [ -z "$out" ] \
            && [ "$(printf '%s\n' "$reasonline" | wc -l | tr -d ' ')" = 1 ] \
            && grep -Fq -- "$reason" <<<"$reasonline" \
            && grep -Fxq 'VARS=|||||' <<<"$err"; then
            test_pass "$label parse rejects $name ($reason)"
        else
            test_fail "$label parse rejects $name ($reason) (rc=$rc out='$out' err='$err')"
        fi
    }
    parse_case "an unknown schema" "unknown schema" 'schema=2\nguest=g\nstate=ready\n'
    parse_case "a non-numeric schema" "unknown schema" 'schema=one\nguest=g\nstate=ready\n'
    parse_case "a missing schema" "missing schema" 'guest=g\nstate=ready\n'
    parse_case "a missing guest" "missing guest" 'schema=1\nstate=ready\n'
    parse_case "a missing state" "missing state" 'schema=1\nguest=g\n'
    parse_case "an unknown state" "unknown state" 'schema=1\nguest=g\nstate=paused\n'
    parse_case "an upper-case state" "unknown state" 'schema=1\nguest=g\nstate=READY\n'
    parse_case "a duplicate guest key" "duplicate key" 'schema=1\nguest=g\nguest=g\nstate=ready\n'
    parse_case "a duplicate state key with different values" "duplicate key" 'schema=1\nguest=g\nstate=copying\nstate=ready\n'
    parse_case "a duplicate optional key" "duplicate key" 'schema=1\nguest=g\nstate=ready\nsource-volume=a\nsource-volume=b\n'
    parse_case "a guest with a space" "invalid guest" 'schema=1\nguest=a b\nstate=ready\n'
    parse_case "a guest with a slash" "invalid guest" 'schema=1\nguest=a/b\nstate=ready\n'
    parse_case "a guest starting with a dash" "invalid guest" 'schema=1\nguest=-a\nstate=ready\n'
    parse_case "a guest with a shell metacharacter" "invalid guest" 'schema=1\nguest=a$b\nstate=ready\n'
    parse_case "a guest with a trailing carriage return" "invalid guest" 'schema=1\nguest=g\r\nstate=ready\n'
    parse_case "an invalid source-volume" "invalid source-volume" 'schema=1\nguest=g\nstate=ready\nsource-volume=../x\n'
    parse_case "a created-at without the Z" "invalid timestamp" 'schema=1\nguest=g\nstate=ready\ncreated-at=2026-10-10T12:34:56\n'
    parse_case "a migrated-at with a space" "invalid timestamp" 'schema=1\nguest=g\nstate=ready\nmigrated-at=2026-10-10 12:34:56Z\n'
    parse_case "a retired-at date only" "invalid timestamp" 'schema=1\nguest=g\nstate=retired\nretired-at=2026-10-10\n'
    parse_case "a month of 13" "invalid timestamp" 'schema=1\nguest=g\nstate=ready\ncreated-at=2026-13-10T12:34:56Z\n'
    parse_case "an hour of 24" "invalid timestamp" 'schema=1\nguest=g\nstate=ready\ncreated-at=2026-10-10T24:00:00Z\n'
    parse_case "an unknown key" "unknown key" 'schema=1\nguest=g\nstate=ready\nowner=root\n'
    parse_case "a line without equals" "malformed line" 'schema=1\nguest=g\nstate=ready\njunk\n'
    parse_case "an empty value" "malformed line" 'schema=1\nguest=\nstate=ready\n'
    parse_case "empty input" "missing" ''

    # blank lines are tolerated; key order on input is free
    printf 'state=ready\n\nguest=g2\nschema=1\n' >"$TMP_ROOT/free.txt"
    out="$("$shell" -c ". \"$LIB\"; dx_persist_marker_parse <\"$TMP_ROOT/free.txt\" && printf '%s|%s\n' \"\$DX_PERSIST_MARKER_GUEST\" \"\$DX_PERSIST_MARKER_STATE\"" 2>&1)"
    if [ "$out" = "g2|ready" ]; then test_pass "$label parse accepts any key order and ignores blank lines"; else test_fail "$label parse accepts any key order and ignores blank lines (got: $out)"; fi
done

# --- side-effect-free sourcing (the section-3 check) ---
for f in "$LIB" "$HOSTLIB"; do
    name="${f#"$BASE_DIR"/}"
    output=""
    if [ -f "$f" ] && output="$(bash "$PROBES/P0.sh" "$f" 2>&1)" && [ -z "$output" ]; then
        test_pass "$name is side-effect-free when sourced"
    else
        test_fail "$name is side-effect-free when sourced ($output)"
    fi
done
output=""
if [ -f "$LIB" ] && output="$(bash "$PROBES/P1.sh" "$LIB" 2>&1)" && [ -z "$output" ]; then
    test_pass "sourcing the library under set -euo pipefail changes nothing"
else
    test_fail "sourcing the library under set -euo pipefail changes nothing ($output)"
fi

# --- reachable through the host module and directly ---
for f in "$HOSTLIB" "$LIB"; do
    missing=""
    for fn in dx_persist_marker_format dx_persist_marker_parse dx_persist_marker_write; do
        bash "$PROBES/P2.sh" "$f" "$fn" 2>/dev/null || missing="$missing $fn"
    done
    if [ -f "$f" ] && [ -z "$missing" ]; then test_pass "${f#"$BASE_DIR"/} defines the marker functions"; else test_fail "${f#"$BASE_DIR"/} defines the marker functions (missing:$missing)"; fi
done
out="$(bash "$PROBES/P3.sh" "$HOSTLIB" 2>&1)"
if [ "$out" = .dxe-persist-dir ]; then test_pass "the host module exposes DX_PERSIST_MARKER_NAME=.dxe-persist-dir"; else test_fail "the host module exposes DX_PERSIST_MARKER_NAME=.dxe-persist-dir (got: $out)"; fi
# From another working directory the host module still finds the library.
out="$(cd "$TMP_ROOT" && bash "$PROBES/P4.sh" "$HOSTLIB" 2>&1)"
if [ "$out" = "$(printf 'schema=1\nguest=hostg\nstate=ready\n')" ]; then test_pass "the host module formats a marker from an unrelated working directory"; else test_fail "the host module formats a marker from an unrelated working directory (got: $out)"; fi

# --- write: recording mv stub ---
HOST_HAS_WRITE=0
bash "$PROBES/P5.sh" "$HOSTLIB" 2>/dev/null && HOST_HAS_WRITE=1
STUBS="$TMP_ROOT/stubs"; mkdir -p "$STUBS"
cat >"$STUBS/mv" <<'STUB'
#!/bin/sh
printf '%s\n' "$#" >>"$MV_LOG"
for a in "$@"; do printf 'ARG=%s\n' "$a" >>"$MV_LOG"; done
if [ "${MV_FAIL:-0}" = 1 ]; then exit 1; fi
exec /bin/mv "$@"
STUB
chmod +x "$STUBS/mv"

text="$(printf 'schema=1\nguest=wg\nstate=ready\ncreated-at=%s\n' "$T_TS")"
D="$TMP_ROOT/dir1"; mkdir -p "$D"
export MV_LOG="$TMP_ROOT/mv.log"; : >"$MV_LOG"
out="$(PATH="$STUBS:$PATH" bash "$PROBES/P6.sh" "$HOSTLIB" "$D" "$text" 2>&1)"; rc=$?
src="$(grep '^ARG=' "$MV_LOG" | sed -n 1p | sed 's/^ARG=//')"
dst="$(grep '^ARG=' "$MV_LOG" | sed -n 2p | sed 's/^ARG=//')"
if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ "$(sed -n 1p "$MV_LOG")" = 2 ] && [ "$(grep -c '^ARG=' "$MV_LOG")" = 2 ]; then test_pass "write runs exactly one two-argument mv and prints nothing"; else test_fail "write runs exactly one two-argument mv and prints nothing (rc=$rc out='$out' log=$(tr '\n' ' ' <"$MV_LOG"))"; fi
if [ "$dst" = "$D/.dxe-persist-dir" ]; then test_pass "write's mv target is <dir>/.dxe-persist-dir"; else test_fail "write's mv target is <dir>/.dxe-persist-dir (got: $dst)"; fi
if [ -n "$src" ] && [ "$(dirname "$src")" = "$D" ] && [ "$src" != "$dst" ]; then test_pass "write's mv source is a different file in the same directory"; else test_fail "write's mv source is a different file in the same directory (got: $src)"; fi
if [ "$(cat "$D/.dxe-persist-dir" 2>/dev/null)" = "$text" ] && [ ! -e "$src" ]; then test_pass "write leaves the exact text and consumes the temporary file"; else test_fail "write leaves the exact text and consumes the temporary file"; fi

# mv stub records the temp file's content at call time (written before mv).
cat >"$STUBS/mv" <<'STUB'
#!/bin/sh
cp "$1" "$MV_SNAPSHOT"
if [ "${MV_FAIL:-0}" = 1 ]; then exit 1; fi
exec /bin/mv "$@"
STUB
export MV_SNAPSHOT="$TMP_ROOT/snapshot"
D2="$TMP_ROOT/dir2"; mkdir -p "$D2"
PATH="$STUBS:$PATH" bash "$PROBES/P6.sh" "$HOSTLIB" "$D2" "$text" >/dev/null 2>&1
if [ "$(cat "$MV_SNAPSHOT" 2>/dev/null)" = "$text" ]; then test_pass "the temporary file is complete before mv runs"; else test_fail "the temporary file is complete before mv runs"; fi

# --- write: real directory, no stub ---
D3="$TMP_ROOT/dir3 with space"; mkdir -p "$D3"
if bash "$PROBES/P6.sh" "$HOSTLIB" "$D3" "$text" >/dev/null 2>&1 \
    && [ "$(cat "$D3/.dxe-persist-dir")" = "$text" ] \
    && [ "$(ls -A "$D3")" = ".dxe-persist-dir" ]; then
    test_pass "write on a real directory (with a space) leaves exactly the marker and nothing else"
else
    test_fail "write on a real directory (with a space) leaves exactly the marker and nothing else ($(ls -A "$D3" 2>&1 | tr '\n' ' '))"
fi
text2="$(printf 'schema=1\nguest=wg\nstate=retired\nretired-at=%s\n' "$T_TS2")"
if bash "$PROBES/P6.sh" "$HOSTLIB" "$D3" "$text2" >/dev/null 2>&1 \
    && [ "$(cat "$D3/.dxe-persist-dir")" = "$text2" ] && [ "$(ls -A "$D3")" = ".dxe-persist-dir" ]; then
    test_pass "write replaces an existing marker atomically in place"
else
    test_fail "write replaces an existing marker atomically in place"
fi

# failing mv: previous marker unchanged, non-zero, no temp left behind
before="$(cat "$D3/.dxe-persist-dir")"
PATH="$STUBS:$PATH" MV_FAIL=1 bash "$PROBES/P6.sh" "$HOSTLIB" "$D3" "$text" >/dev/null 2>&1; rc=$?
if [ "$HOST_HAS_WRITE" = 1 ] && [ "$rc" -ne 0 ] && [ "$(cat "$D3/.dxe-persist-dir")" = "$before" ] && [ "$(ls -A "$D3")" = ".dxe-persist-dir" ]; then
    test_pass "a failing mv returns non-zero, keeps the previous marker and leaves no temporary file"
else
    test_fail "a failing mv returns non-zero, keeps the previous marker and leaves no temporary file (rc=$rc dir=$(ls -A "$D3" | tr '\n' ' '))"
fi
D4="$TMP_ROOT/dir4"; mkdir -p "$D4"
PATH="$STUBS:$PATH" MV_FAIL=1 bash "$PROBES/P6.sh" "$HOSTLIB" "$D4" "$text" >/dev/null 2>&1; rc=$?
if [ "$HOST_HAS_WRITE" = 1 ] && [ "$rc" -ne 0 ] && [ -z "$(ls -A "$D4")" ]; then test_pass "a failing mv with no previous marker creates no marker and no temporary file"; else test_fail "a failing mv with no previous marker creates no marker and no temporary file (rc=$rc)"; fi

# invalid text: nothing written, mv never runs
: >"$MV_LOG"
cat >"$STUBS/mv" <<'STUB'
#!/bin/sh
echo called >>"$MV_LOG"
exec /bin/mv "$@"
STUB
D5="$TMP_ROOT/dir5"; mkdir -p "$D5"
PATH="$STUBS:$PATH" bash "$PROBES/P6.sh" "$HOSTLIB" "$D5" "$(printf 'schema=1\nguest=g\nstate=paused\n')" >/dev/null 2>&1; rc=$?
if [ "$HOST_HAS_WRITE" = 1 ] && [ "$rc" -ne 0 ] && [ -z "$(ls -A "$D5")" ] && [ ! -s "$MV_LOG" ]; then test_pass "write refuses invalid marker text without touching the directory or running mv"; else test_fail "write refuses invalid marker text without touching the directory or running mv (rc=$rc)"; fi
bash "$PROBES/P6.sh" "$HOSTLIB" "$TMP_ROOT/nonexistent" "$text" >/dev/null 2>&1; rc=$?
if [ "$HOST_HAS_WRITE" = 1 ] && [ "$rc" -ne 0 ] && [ ! -e "$TMP_ROOT/nonexistent" ]; then test_pass "write to a missing directory fails and creates nothing"; else test_fail "write to a missing directory fails and creates nothing (rc=$rc)"; fi

print_summary
exit_with_code
