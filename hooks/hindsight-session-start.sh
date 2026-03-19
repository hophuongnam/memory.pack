#!/bin/bash
# SessionStart hook: replay previous session via Hindsight in background.
# Replay runs async; boot context written to .hindsight-boot-context
# for the UserPromptSubmit hook to pick up on a subsequent turn.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
MARKER="$SCRIPT_DIR/.last-session"
BOOT_CTX="$SCRIPT_DIR/.hindsight-boot-context"

# Read current session ID from hook input
INPUT=$(cat)
CURRENT_ID=$(echo "$INPUT" | jq -r '.session_id // empty')

[ ! -f "$MARKER" ] && exit 0
PREV_ID=$(cat "$MARKER")
[ -z "$PREV_ID" ] && exit 0

# Guard: never replay our own session
[ "$PREV_ID" = "$CURRENT_ID" ] && exit 0

# Clean stale boot context from previous cycle
rm -f "$BOOT_CTX"

# Background: replay previous session, write boot context to temp file,
# then atomically rename to final path when done (avoids race with inject hook).
nohup sh -c "node \"$SCRIPT_DIR/hindsight-replay.mjs\" \"$PREV_ID\" \"$PWD\" \
  >\"$BOOT_CTX.tmp\" 2>/tmp/hindsight-replay-error.log \
  && [ -s \"$BOOT_CTX.tmp\" ] && mv \"$BOOT_CTX.tmp\" \"$BOOT_CTX\" \
  || rm -f \"$BOOT_CTX.tmp\"" </dev/null &>/dev/null &
disown

echo "SessionStart:startup hook success: Replaying session ${PREV_ID:0:8} in background — context will arrive on a subsequent turn."
