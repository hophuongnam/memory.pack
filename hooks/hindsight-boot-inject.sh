#!/bin/bash
# Inject Hindsight boot context from previous session's replay.
# Wired to both SessionStart (immediate) and UserPromptSubmit (fallback).
# Checks for .hindsight-boot-context written by hindsight-session-end.sh.
# On SessionStart: also prompts to recall from hindsight for relevant context.
# Tracks replay status via .hindsight-replay-pid to inform when replay is still running.
INPUT=$(cat)
EVENT=$(echo "$INPUT" | jq -r '.hook_event_name // "UserPromptSubmit"')

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_CTX="$SCRIPT_DIR/.hindsight-boot-context"
PID_FILE="$SCRIPT_DIR/.hindsight-replay-pid"

# Per-project boot status for statusline
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
PROJECT_HASH=$(echo -n "$PROJECT_DIR" | md5 | head -c 8)
BOOT_STATUS_FILE="/tmp/claude-statusline/boot-status-${PROJECT_HASH}"
mkdir -p /tmp/claude-statusline

# Check if replay is still running
replay_running() {
  [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE" 2>/dev/null)" 2>/dev/null
}

CONTEXT=""

if [ "$EVENT" = "UserPromptSubmit" ] && [ ! -f "$BOOT_CTX" ] && replay_running; then
  # Poll up to 5s for replay to finish
  for i in 1 2 3 4 5; do
    sleep 1
    if [ -f "$BOOT_CTX" ]; then
      break
    fi
    replay_running || break
  done
fi

STATUS=""
if [ -f "$BOOT_CTX" ]; then
  CONTEXT=$(cat "$BOOT_CTX")
  rm -f "$BOOT_CTX"
  STATUS="[Boot context loaded from previous session replay.]"
  echo "loaded" > "$BOOT_STATUS_FILE"
elif replay_running; then
  STATUS="[Previous session replay is still processing. Boot context from the last session is not yet available.]"
  echo "pending" > "$BOOT_STATUS_FILE"
else
  STATUS="[No boot context available from previous session.]"
  echo "none" > "$BOOT_STATUS_FILE"
fi

if [ -n "$CONTEXT" ]; then
  CONTEXT="$STATUS

$CONTEXT"
else
  CONTEXT="$STATUS"
fi

# On SessionStart, append hindsight recall prompt
if [ "$EVENT" = "SessionStart" ]; then
  RECALL_PROMPT="Use the hindsight skill to recall relevant context before starting work. Check for active TODOs, recent decisions, and conventions related to the user's request."
  if [ -n "$CONTEXT" ]; then
    CONTEXT="$CONTEXT

$RECALL_PROMPT"
  else
    CONTEXT="$RECALL_PROMPT"
  fi
fi

if [ -n "$CONTEXT" ]; then
  jq -n --arg ctx "$CONTEXT" --arg event "$EVENT" '{
    hookSpecificOutput: {
      hookEventName: $event,
      additionalContext: $ctx
    }
  }'
fi

exit 0
