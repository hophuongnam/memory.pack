#!/bin/sh
# Memory.Pack Stop hook: TTL-gate + detach the per-model usage refresh.
#
# All this script decides is WHETHER to fetch; fetch-usage-worker.sh decides
# how. The split keeps a network round-trip off the end of every turn (the
# worker is detached, so a dead endpoint stalls nothing) and keeps the gate
# synchronously testable without racing an orphaned child.
#
# Parses no stdin field, so there is no snake↔camel surface here (invariant #3).
set -u

# Drain the hook payload we don't use: a hook that exits without reading stdin
# can hand CC a SIGPIPE on a large payload.
cat >/dev/null 2>&1

CACHE="$HOME/.claude/hook_state/usage_scoped"
TTL=120

if [ -f "$CACHE" ]; then
    fetched=""
    read -r fetched < "$CACHE" 2>/dev/null || fetched=""
    # A torn or tampered stamp must never reach $(( )): under dash (Linux
    # /bin/sh) a non-integer operand is a FATAL arithmetic error that kills the
    # hook, while a bare identifier silently evaluates to 0. See
    # feedback_dash_arith_fatal_on_noninteger. Unparseable → treat as ancient.
    case "$fetched" in ''|*[!0-9]*) fetched=0 ;; esac
    age=$(( $(date +%s) - fetched ))
    # A future stamp (clock skew, restored backup) is not "fresh" — refetch.
    if [ "$age" -ge 0 ] && [ "$age" -lt "$TTL" ]; then
        exit 0
    fi
fi

WORKER="$(cd "$(dirname "$0")" && pwd)/fetch-usage-worker.sh"
[ -x "$WORKER" ] || exit 0

nohup "$WORKER" </dev/null >/dev/null 2>&1 &
exit 0
