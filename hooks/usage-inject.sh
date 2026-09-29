#!/bin/sh
# Memory.Pack PreToolUse hook (matcher: Agent): the quota gate on subagent
# launches.
#
# Goal: the main agent must know the quota BEFORE it launches a subagent.
# PreToolUse fires after the model already decided to launch, so
# additionalContext alone arrives one launch too late. Only a DENY stops the
# call, and its permissionDecisionReason is what reaches the model.
#
# HARD STOP (user decision 2026-09-29): EVERY launch is denied while the 5h
# window is ABOVE 90%. The hook keeps no state and parses no stdin field, so
# there is no snake↔camel surface here (invariant #3). The gate opens by
# itself: the statusline writes a value at or under 90, or the reset time
# passes.
#
# 5h ONLY: the 7d window never gates. Rows with any other label are ignored —
# a file written before this decision still holds a 7d row.
#
# Why not the other subagent hooks (read off the 2.1.284 bundle + real
# transcripts, 2026-09-29): SubagentStop's additionalContext is "delivered to
# the subagent; the subagent continues" — wrong agent, and it BURNS quota.
# PostToolUse on Agent fires at LAUNCH, because every subagent runs in the
# background and the tool returns at once (9 of 9 real results).
#
# FAIL OPEN on the DATA. A false deny is a subagent kill switch, a false
# allow only costs one launch. No cache, torn row, unknown or past reset time
# → exit 0 with NO stdout.
#
# Cache (written by statusline-command.sh from CC's documented rate_limits):
#     <write_epoch>
#     <pct> <resets_epoch> 5h
set -u

# Replay children (MP_REPLAY_CHILD from replay.mjs) run with tools:[] and
# never launch a subagent; the belt, like the other reachable hooks.
[ -n "${MP_REPLAY_CHILD:-}" ] && exit 0

# Drain the payload we don't use: a hook that exits without reading stdin can
# hand CC a SIGPIPE on a large payload.
cat >/dev/null 2>&1

THRESHOLD=90    # strict: the gate trips ABOVE this value

# Per-account (bucket 2): the windows belong to the account CLAUDE_CONFIG_DIR
# selects — see fetch-usage-worker.sh for the bucket reasoning.
CONFIG_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CACHE="${CONFIG_DIR%/}/hook_state/usage_windows"
[ -f "$CACHE" ] || exit 0

now=$(date +%s)
lines=""
age=""
{
    stamp=""
    read -r stamp || stamp=""
    # The stamp feeds only the age text. Int-guard before $(( )): a
    # non-integer operand is FATAL under dash
    # (feedback_dash_arith_fatal_on_noninteger).
    case "$stamp" in ''|*[!0-9]*) ;; *) age=$(( (now - stamp) / 60 )) ;; esac
    while read -r pct reset label; do
        case "$pct"   in ''|*[!0-9]*) continue ;; esac
        case "$reset" in ''|*[!0-9]*) continue ;; esac
        [ "$label" = 5h ] || continue
        [ "$pct" -gt "$THRESHOLD" ] || continue
        # Usage only grows inside a window, so a row is current exactly while
        # its reset time is ahead. Past (or the 0 sentinel) = previous window.
        [ "$reset" -gt "$now" ] || continue
        left=$(( reset - now ))
        if [ "$left" -ge 86400 ]; then
            in="$(( left / 86400 ))d $(( left % 86400 / 3600 ))h"
        else
            in="$(( left / 3600 ))h $(( left % 3600 / 60 ))m"
        fi
        lines="${lines}${label} window: ${pct}% used, resets in ${in}. "
    done
} < "$CACHE"
[ -n "$lines" ] || exit 0

reason="Subagent launches are blocked (usage quota, not an error). ${lines}${age:+Snapshot age: ${age} min. }A subagent uses this same quota. Do not send this Agent call again: each launch is denied until the window is at 90% or less, or until the reset. Tell the user the numbers, then do the work inline or do less."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
