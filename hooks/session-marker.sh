#!/bin/bash
# Stop hook: write current session ID to marker file for next-session boot.
# Skip trivial sessions (≤5 user turns) to avoid overwriting real work sessions.
INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')

[ -z "$SESSION_ID" ] && exit 0

# Count user turns from transcript JSONL
TURNS=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TURNS=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)
fi

if [ "$TURNS" -gt 5 ]; then
  echo "$SESSION_ID" > "$(dirname "$0")/.last-session"
fi
