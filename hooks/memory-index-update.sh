#!/bin/bash
# PostToolUse hook — keep the auto-memory FTS5 index in sync after a Write,
# Edit, or MultiEdit to a memory file. Single-file upsert, backgrounded
# so the hook returns instantly and never gates the agent.
#
# Race note vs archive-resurrect.sh: both fire on PostToolUse:Write. The
# resurrector only mutates frontmatter fields (created/recall_count/
# last_reviewed/last_recalled) — none of which are FTS columns — so even
# if the indexer wins the race and reads the pre-resurrect file, the
# searchable content (type/name/description/body) is identical. The full
# reconcile at SessionEnd catches anything else (manual mv, git restore,
# /memory-lint deletions).

INPUT=$(cat)

# Bilingual snake↔camel per invariant #3 (reference_cc_hook_input_fields.md).
TOOL=$(echo "$INPUT" | jq -r '.tool_name // .toolName // empty')
case "$TOOL" in
  Write|Edit|MultiEdit) ;;
  *) exit 0 ;;
esac

FILE_PATH=$(echo "$INPUT" | jq -r '(.tool_input // .toolInput // {}).file_path // empty')
[ -n "$FILE_PATH" ] || exit 0

# Only memory files under ~/.claude/projects/<slug>/memory/ — including
# anything under archive/. Note the more permissive glob compared to
# archive-resurrect.sh (which deliberately skips archive/ writes).
case "$FILE_PATH" in
  "$HOME"/.claude/projects/*/memory/*.md) ;;
  "$HOME"/.claude/projects/*/memory/*/*.md) ;;
  *) exit 0 ;;
esac

# Skip index/sessions/pending/dotfiles. Same skip list as archive-resurrect.sh.
BASENAME=$(basename "$FILE_PATH")
case "$BASENAME" in
  MEMORY.md|SESSIONS.md|sessions.log.md|PENDING_MEMORIES.md|SCHEMA.md) exit 0 ;;
  .*) exit 0 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INDEXER="$SCRIPT_DIR/../index/index-memories.py"

# Background and disown so the hook returns in <10ms.
nohup python3 "$INDEXER" --file "$FILE_PATH" --quiet \
  >/dev/null 2>&1 </dev/null &
disown 2>/dev/null || true

exit 0
