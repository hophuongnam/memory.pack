#!/bin/bash
# PostToolUse hook — auto-resurrect archived memories on slug collision.
# Fires on every tool use; fast-paths everything that isn't a Write to a
# memory file path and spawns the resurrector in the background so the
# hook never blocks the agent's next step.

INPUT=$(cat)

# Bilingual snake↔camel per invariant #3 (reference_cc_hook_input_fields.md).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')
[ "$TOOL" = "Write" ] || exit 0

FILE_PATH=$(echo "$INPUT" | jq -r '(.tool_input // .toolInput // {}).file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Only memory files under ~/.claude/projects/<slug>/memory/. Skip writes
# into archive/ itself — those are user-driven re-archives, not new writes.
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*/*) exit 0 ;;
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  *) exit 0 ;;
esac

# Skip index / sessions / pending artifacts and dotfiles.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  MEMORY.md|SESSIONS.md|sessions.log.md|PENDING_MEMORIES.md|SCHEMA.md) exit 0 ;;
  .*) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Background the resurrector. Disown so the shell doesn't wait on it.
nohup node "$SCRIPT_DIR/archive-resurrect.mjs" "$FILE_PATH" \
  >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
