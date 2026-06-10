#!/bin/bash
# PostToolUse hook — tracks recalls of auto-memory files.
# Fires on every tool use; fast-paths everything that isn't a Read of a
# memory file and spawns the updater in the background so the hook never
# blocks the agent's next step.

INPUT=$(cat)

# Bilingual snake↔camel per invariant #3 (reference_cc_hook_input_fields.md).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')
[ "$TOOL" = "Read" ] || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '(.tool_input // .toolInput // {}).file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Only memory files under ~/.claude/projects/<slug>/memory/
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac

# Skip index / pending / sessions artifacts — not memories.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  MEMORY.md|SESSIONS.md|sessions.log.md|PENDING_MEMORIES.md|SCHEMA.md) exit 0 ;;
esac
# Reads under .../memory/archive/ now DO bump recall — update-recall.mjs
# routes archived hits through a promotion check (see SCHEMA.md
# "Auto-promote on recall threshold") and atomically moves the file
# back to active when its post-archive recall_count clears the bar.

SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // .sessionId // empty')
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Background the updater. Disown so the shell doesn't wait on it.
nohup node "$SCRIPT_DIR/update-recall.mjs" "$FILE_PATH" "$SESSION_ID" \
  >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
