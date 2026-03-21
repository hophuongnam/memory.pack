#!/bin/bash
# SessionEnd hook: launch replay of ending session for Hindsight.
# Replay runs detached via nohup; boot context written to .hindsight-boot-context
# for the UserPromptSubmit hook to inject on the next session's first turn.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BOOT_CTX="$SCRIPT_DIR/.hindsight-boot-context"

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty')
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
CWD=$(echo "$INPUT" | jq -r '.cwd // empty')

[ -z "$SESSION_ID" ] && exit 0

# Skip trivial sessions (≤5 user turns)
TURNS=0
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  TURNS=$(grep -c '"type":"user"' "$TRANSCRIPT" 2>/dev/null || echo 0)
fi
[ "$TURNS" -le 5 ] && exit 0

# Resolve replay script location (follow symlinks to find co-located replay.mjs)
SCRIPT_PATH="$SCRIPT_DIR/$(basename "$0")"
REAL_DIR="$(cd "$SCRIPT_DIR" && cd "$(dirname "$(readlink "$SCRIPT_PATH" 2>/dev/null || echo "$SCRIPT_PATH")")" && pwd)"
REPLAY="$REAL_DIR/hindsight-replay.mjs"
[ ! -f "$REPLAY" ] && REPLAY="$SCRIPT_DIR/hindsight-replay.mjs"

# Clean stale boot context and PID file
rm -f "$BOOT_CTX" "$BOOT_CTX.tmp" "$SCRIPT_DIR/.hindsight-replay-pid"

# Detach replay: write boot context atomically for next session's inject hook
nohup sh -c "echo \$\$ >\"$SCRIPT_DIR/.hindsight-replay-pid\" && \
  node \"$REPLAY\" \"$SESSION_ID\" \"${CWD:-$PWD}\" \
  >\"$BOOT_CTX.tmp\" 2>/tmp/hindsight-replay-error.log \
  && [ -s \"$BOOT_CTX.tmp\" ] && mv \"$BOOT_CTX.tmp\" \"$BOOT_CTX\" \
  || rm -f \"$BOOT_CTX.tmp\"; \
  rm -f \"$SCRIPT_DIR/.hindsight-replay-pid\"" </dev/null &>/dev/null &
disown
