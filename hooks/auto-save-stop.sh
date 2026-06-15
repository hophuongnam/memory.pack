#!/bin/bash
# AUTO-SAVE STOP HOOK — Save to internal memory every N exchanges
#
# Claude Code "Stop" hook. After every assistant response:
# 1. Counts REAL human turns AND transcript bytes since the last save
# 2. Every SAVE_INTERVAL turns OR MP_AUTOSAVE_MIN_BYTES bytes, BLOCKS the AI
#    from stopping (the byte axis checkpoints tool-heavy, few-turn sessions)
# 3. Returns a reason telling the AI to save to its internal memory system
# 4. AI saves, tries to stop again — stop_hook_active=true lets it through
#
# === CONFIGURATION ===

SAVE_INTERVAL=10
# Tool-heavy sessions accumulate few REAL turns (a measured 2026-06-13 session
# held only 2 across 2MB of transcript) but lots of bytes, so a turn-only gate
# never checkpoints them → silent amnesia. ALSO trip when the transcript grows
# this many bytes since the last size-save. Env-tunable; same magnitude as
# session-end's MP_REPLAY_MIN_BYTES floor. Set very high to disable the axis.
MP_AUTOSAVE_MIN_BYTES="${MP_AUTOSAVE_MIN_BYTES:-200000}"
STATE_DIR="$HOME/.claude/hook_state"
mkdir -p "$STATE_DIR"

# GC — this state grew unboundedly before (759 per-session files + 478KB
# log observed 2026-06-10): prune per-session save markers older than 7
# days and rotate hook.log past 512KB down to its newest 500 lines.
# tail+mv rotation can lose a concurrent Stop's log line — debug log only,
# never engine state, so last-writer-wins is acceptable. Both per-session
# state files (*_last_save + the statusline's *_turns countdown cache) share
# this prune — same lifecycle, or *_turns would leak one file per session.
find "$STATE_DIR" \( -name '*_last_save' -o -name '*_turns' \) -type f -mtime +7 -delete 2>/dev/null
if [ -f "$STATE_DIR/hook.log" ]; then
    _log_bytes=$(wc -c < "$STATE_DIR/hook.log" 2>/dev/null | tr -d ' ')
    if [ -n "$_log_bytes" ] && [ "$_log_bytes" -gt 524288 ] 2>/dev/null; then
        tail -n 500 "$STATE_DIR/hook.log" > "$STATE_DIR/hook.log.tmp.$$" 2>/dev/null \
            && mv "$STATE_DIR/hook.log.tmp.$$" "$STATE_DIR/hook.log"
        rm -f "$STATE_DIR/hook.log.tmp.$$" 2>/dev/null
    fi
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# Shared turn counter lives in _lib.sh. If sourcing fails, let the stop
# through quietly — auto-save is a nicety, never worth blocking CC over.
. "$SCRIPT_DIR/_lib.sh" 2>/dev/null || { echo "{}"; exit 0; }

# Read JSON input from stdin
INPUT=$(cat)

# Parse fields. Bilingual snake↔camel per invariant #3 — CC's stdin field
# naming drifts between releases (see reference_cc_hook_input_fields.md);
# a snake-only read here silently disables auto-save when camelCase arrives.
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // "unknown"' 2>/dev/null)
SESSION_ID=$(echo "$SESSION_ID" | tr -cd 'a-zA-Z0-9_-')
[ -z "$SESSION_ID" ] && SESSION_ID="unknown"
STOP_HOOK_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // .stopHookActive // false' 2>/dev/null)
TRANSCRIPT_PATH=$(echo "$INPUT" | jq -r '.transcript_path // .transcriptPath // ""' 2>/dev/null)
TRANSCRIPT_PATH="${TRANSCRIPT_PATH/#\~/$HOME}"

# If already in a save cycle, let the AI stop normally
if [ "$STOP_HOOK_ACTIVE" = "True" ] || [ "$STOP_HOOK_ACTIVE" = "true" ]; then
    echo "{}"
    exit 0
fi

# Count REAL human exchanges in the JSONL transcript. The old role=="user"
# count included tool_results (array-content user entries) and isMeta
# bookkeeping, so "50 exchanges" actually meant ~50 transcript entries — a
# handful of real turns in tool-heavy sessions (hook.log shows triggers at
# "exchange 179/237"). _mp_real_user_turns counts only genuine prompts.
EXCHANGE_COUNT=$(_mp_real_user_turns "$TRANSCRIPT_PATH")

# Track last save point for this session. The state file holds two INDEPENDENT
# baselines: "<turns_at_last_turn_save> <bytes_at_last_byte_save>". Independent
# so a size-save never resets the turn countdown and vice versa — coupling them
# would peg the statusline countdown near-full in tool-heavy sessions while
# saves kept firing on the byte axis. Backward-compatible: a legacy one-field
# file (bare turn count) reads the bytes baseline as 0, which just lets the
# first post-upgrade Stop checkpoint an already-large in-progress session.
LAST_SAVE_FILE="$STATE_DIR/${SESSION_ID}_last_save"
LAST_SAVE=0
LAST_SAVE_BYTES=0
if [ -f "$LAST_SAVE_FILE" ]; then
    read LAST_SAVE LAST_SAVE_BYTES < "$LAST_SAVE_FILE"
fi
# Both baselines must be pure integers before arithmetic — a torn or legacy
# file must not break the count.
case "$LAST_SAVE"       in ''|*[!0-9]*) LAST_SAVE=0 ;; esac
case "$LAST_SAVE_BYTES" in ''|*[!0-9]*) LAST_SAVE_BYTES=0 ;; esac

# Current transcript size = the byte axis. Guarded: missing/unreadable → 0,
# and EXCHANGE_COUNT is also 0 on those same sessions, so the axis stays dormant.
TRANSCRIPT_BYTES=0
if [ -n "$TRANSCRIPT_PATH" ] && [ -f "$TRANSCRIPT_PATH" ]; then
    TRANSCRIPT_BYTES=$(wc -c < "$TRANSCRIPT_PATH" 2>/dev/null | tr -d ' ')
fi
case "$TRANSCRIPT_BYTES" in ''|*[!0-9]*) TRANSCRIPT_BYTES=0 ;; esac

SINCE_LAST=$((EXCHANGE_COUNT - LAST_SAVE))
BYTES_SINCE=$((TRANSCRIPT_BYTES - LAST_SAVE_BYTES))

echo "[$(date '+%H:%M:%S')] Session $SESSION_ID: $EXCHANGE_COUNT exchanges, $SINCE_LAST since save, ${BYTES_SINCE}B since byte-save" >> "$STATE_DIR/hook.log"

# Cache the turn-countdown state for the statusline's line-1 indicator:
# "<since_last> <interval>". Costs nothing extra — EXCHANGE_COUNT was already
# computed above; the statusline reads this with a plain shell `read` instead
# of re-parsing the transcript (which would blow its ≤3-jq-fork budget). The
# countdown tracks the TURN axis only — the size axis (MP_AUTOSAVE_MIN_BYTES)
# can fire a save independently WITHOUT resetting it, so the count is "turns
# until the turn-based save": an upper bound on the next save, not a guarantee
# none fires sooner. Independent baselines (trigger branch below) keep this
# turn count honest across size-saves.
# Skipped on 0-turn Stops (headless run, or a transient transcript-read race
# yielding 0) so the indicator stays clean / keeps its last good value rather
# than flickering to a full interval. Written BEFORE the trigger branch so it
# reflects the SINCE_LAST that fired the block; the next turn's Stop resets it.
if [ "$EXCHANGE_COUNT" -gt 0 ] 2>/dev/null; then
    printf '%s %s\n' "$SINCE_LAST" "$SAVE_INTERVAL" > "$STATE_DIR/${SESSION_ID}_turns"
fi

# Time to save? Either axis fires: SAVE_INTERVAL real turns, OR a large chunk of
# new transcript (tool-heavy work that never accumulates turns). EXCHANGE_COUNT>0
# guard keeps headless / 0-turn runs from ever blocking.
if { [ "$SINCE_LAST" -ge "$SAVE_INTERVAL" ] || [ "$BYTES_SINCE" -ge "$MP_AUTOSAVE_MIN_BYTES" ]; } && [ "$EXCHANGE_COUNT" -gt 0 ]; then
    # Advance ONLY the axis/axes that fired — independent baselines so a
    # size-save never resets the turn countdown (and vice versa).
    NEW_SAVE="$LAST_SAVE"
    NEW_SAVE_BYTES="$LAST_SAVE_BYTES"
    [ "$SINCE_LAST"  -ge "$SAVE_INTERVAL" ]         && NEW_SAVE="$EXCHANGE_COUNT"
    [ "$BYTES_SINCE" -ge "$MP_AUTOSAVE_MIN_BYTES" ] && NEW_SAVE_BYTES="$TRANSCRIPT_BYTES"
    printf '%s %s\n' "$NEW_SAVE" "$NEW_SAVE_BYTES" > "$LAST_SAVE_FILE"
    echo "[$(date '+%H:%M:%S')] TRIGGERING SAVE at exchange $EXCHANGE_COUNT (${TRANSCRIPT_BYTES}B)" >> "$STATE_DIR/hook.log"

    SCHEMA_REF="${MEMORY_PACK_HOME:-$HOME/.memory-pack}/SCHEMA.md"
    cat << HOOKJSON
{
  "decision": "block",
  "reason": "AUTO-SAVE checkpoint reached. Review this session and save anything worth preserving to the per-project memory store (~/.claude/projects/*/memory/). Focus on: key decisions, non-obvious learnings, user preferences, project state. Follow the canonical auto-memory schema at $SCHEMA_REF — it defines types, frontmatter, MEMORY.md section grouping, ≤150-char index entries, and the 150-line soft cap **on MEMORY.md** (the harness hard-truncates MEMORY.md at 200 lines or 25KB; this cap applies ONLY to the MEMORY.md index file, NOT to individual per-memory files, which have no length limit). Update existing memories on the same topic instead of creating duplicates. Then continue or end as appropriate."
}
HOOKJSON
else
    echo "{}"
fi
