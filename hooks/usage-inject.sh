#!/bin/sh
# Memory.Pack PreToolUse hook (matcher: Agent): the quota gate on subagent
# launches.
#
# Goal: the main agent must know the quota BEFORE it launches a subagent.
# PreToolUse fires after the model already decided to launch, so
# additionalContext alone arrives one launch too late. Only a DENY stops the
# call, and its permissionDecisionReason is what reaches the model. So: when
# the 5h window is ABOVE 90%, deny ONCE per session with the numbers in the
# reason; the model decides again and the re-issued call passes.
#
# 5h ONLY (user decision 2026-09-29): the 7d window never gates. Rows with
# any other label are ignored — a file written
# before this decision still holds a 7d row.
#
# Why not the other subagent hooks (read off the 2.1.284 bundle + real
# transcripts, 2026-09-29): SubagentStop's additionalContext is "delivered to
# the subagent; the subagent continues" — wrong agent, and it BURNS quota.
# PostToolUse on Agent fires at LAUNCH, because every subagent runs in the
# background and the tool returns at once (9 of 9 real results).
#
# FAIL OPEN, everywhere. This hook blocks a tool call; a false deny is a
# subagent kill switch, a false allow only costs one warning. No cache, torn
# row, unknown reset time, no session id → exit 0 with NO stdout.
#
# Cache (written by statusline-command.sh from CC's documented rate_limits):
#     <write_epoch>
#     <pct> <resets_epoch> 5h
set -u

# Replay children (MP_REPLAY_CHILD from replay.mjs) run with tools:[] and
# never launch a subagent; the belt, like the other reachable hooks.
[ -n "${MP_REPLAY_CHILD:-}" ] && exit 0

input=$(cat)

THRESHOLD=90    # strict: the gate trips ABOVE this value
BATCH=3         # seconds: parallel Agent calls in ONE message are all denied.
                # Keep it SHORT: the reason promises the next call passes.
REARM=3600      # seconds: a long session is warned again

# Per-account (bucket 2): the windows belong to the account CLAUDE_CONFIG_DIR
# selects. The once-only marker below is per SESSION and stays on the shared
# $HOME/.claude — see fetch-usage-worker.sh for the bucket reasoning.
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

# --- deny once per session ---
# jq only past the threshold: the common path above is fork-free but `date`.
sid=$(printf '%s' "$input" | jq -r '.session_id // .sessionId // empty' 2>/dev/null) || sid=""
# The id lands in a path: anything but a plain id fails open.
case "$sid" in ''|*[!A-Za-z0-9_-]*) exit 0 ;; esac
MARK="$HOME/.claude/hook_state/${sid}_quota_warned"
warned=""
[ -f "$MARK" ] && { read -r warned < "$MARK" 2>/dev/null || warned=""; }
# Torn or absent marker → -1 = "never warned". A future stamp (clock skew)
# goes negative too, and is warned again rather than trusted.
case "$warned" in ''|*[!0-9]*) since=-1 ;; *) since=$(( now - warned )) ;; esac
# The re-issued call: warned already, and past the batch window.
[ "$since" -ge "$BATCH" ] && [ "$since" -lt "$REARM" ] && exit 0
# 0 <= since < BATCH is a sibling of the denied batch: deny, keep the stamp.
if [ "$since" -lt 0 ] || [ "$since" -ge "$REARM" ]; then
    # No marker written = no way to let the next call pass → fail open.
    printf '%s\n' "$now" > "$MARK" 2>/dev/null || exit 0
fi

reason="Usage quota check (one time, not an error). ${lines}${age:+Snapshot age: ${age} min; usage only grows inside a window, so the real value is at least this. }A subagent uses this same quota. Tell the user the numbers, then decide: do the work inline, do less, or send the same Agent call again. The next Agent call passes."

jq -n --arg r "$reason" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason: $r
  }
}'
exit 0
